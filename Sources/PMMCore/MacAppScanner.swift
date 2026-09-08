import Foundation

struct MacAppScanner: @unchecked Sendable {
    static let cacheLifetime: TimeInterval = 6 * 60 * 60

    let runner: CommandRunning
    let fileManager: FileManager
    let applicationDirectories: [URL]
    let brew: String?
    let mdls: String
    let session: URLSession
    let cacheURL: URL
    let now: @Sendable () -> Date
    let storefrontCountry: String
    var nativeManager: NativeCaskManager? = nil

    func scan(database: PackageDatabase, mode: PackageScanMode) async throws -> [ManagedPackage] {
        let nativeEnabled = try await nativeCaskWork { (nativeManager ?? NativeCaskManager()).managementEnabled() }
        let discovered = try await discover(database: database)
        var cache = MacAppVersionCache.load(from: cacheURL)

        if mode == .local {
            return discovered.map { package in
                cache.records[package.id].flatMap { record in
                    package.nativeCaskInstallation != nil && record.source != .homebrewCask ? nil : record
                }.map { package.applying($0, catalog: database.app(for: package.bundleIdentifier ?? "")) }
                    ?? package
            }
        }

        var enriched = [String: ManagedPackage]()
        var checkedRecords = [String: MacAppVersionCacheRecord]()
        let cachedRecords = cache.records
        for start in stride(from: 0, to: discovered.count, by: 4) {
            let end = min(start + 4, discovered.count)
            await withTaskGroup(of: MacAppCheckResult.self) { group in
                for package in discovered[start..<end] {
                    group.addTask {
                        await check(
                            package,
                            database: database,
                            cached: cachedRecords[package.id],
                            ignoresCache: mode.ignoresCache,
                            nativeEnabled: nativeEnabled
                        )
                    }
                }
                for await result in group {
                    enriched[result.package.id] = result.package
                    if let record = result.record {
                        checkedRecords[result.package.id] = record
                    }
                }
            }
        }

        for (id, record) in checkedRecords {
            cache.records[id] = record
        }
        try? cache.save(to: cacheURL, fileManager: fileManager)
        return discovered.map { enriched[$0.id] ?? $0 }
    }

    private func discover(database: PackageDatabase) async throws -> [ManagedPackage] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try discoverSynchronously(database: database))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func discoverSynchronously(database: PackageDatabase) throws -> [ManagedPackage] {
        let homebrewPaths = installedHomebrewAppPaths()
        let nativeManager = nativeManager ?? NativeCaskManager(runner: runner, session: session,
            directory: cacheURL.deletingLastPathComponent(), applicationDirectories: applicationDirectories)
        let nativeReceipts = try nativeManager.installations()
        var seenPaths = Set<String>()
        var packages = [ManagedPackage]()

        for root in applicationDirectories where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seenPaths.insert(path).inserted, !homebrewPaths.contains(path),
                      let info = infoDictionary(for: url),
                      let bundleIdentifier = nonEmpty(info["CFBundleIdentifier"] as? String) else { continue }

                let catalog = database.app(for: bundleIdentifier)
                let hasReceipt = fileManager.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
                guard !bundleIdentifier.hasPrefix("com.apple.") || hasReceipt || catalog != nil else { continue }

                let provenance: MacAppProvenance
                if hasReceipt {
                    provenance = .appStore
                } else if isInsideSetapp(url) {
                    provenance = .setapp
                } else {
                    provenance = .direct
                }

                let displayName = nonEmpty(info["CFBundleDisplayName"] as? String)
                    ?? nonEmpty(info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let installedVersion = nonEmpty(info["CFBundleShortVersionString"] as? String)
                    ?? nonEmpty(info["CFBundleVersion"] as? String)
                let bundleVersion = nonEmpty(info["CFBundleVersion"] as? String)
                let feedURL = catalog?.feedURL ?? nonEmpty(info["SUFeedURL"] as? String)

                let native = nativeReceipts.values.first {
                    $0.appPath == path && provenance == .direct && nativeManager.matches($0, app: url)
                }
                let recordedVersion = native.flatMap {
                    $0.shortVersion == installedVersion && $0.bundleVersion == bundleVersion ? $0.version : nil
                }
                packages.append(ManagedPackage(
                    manager: .macApp,
                    identifier: "mac-app:\(bundleIdentifier)",
                    catalogIdentifier: (native?.token ?? catalog?.cask).map { "brew:cask:\($0)" },
                    displayName: displayName,
                    installedVersion: recordedVersion ?? installedVersion,
                    latestVersion: nil,
                    summary: catalog?.summary,
                    category: catalog?.category,
                    homepage: catalog?.homepage,
                    installLocation: path,
                    bundleIdentifier: bundleIdentifier,
                    bundleVersion: bundleVersion,
                    appProvenance: provenance,
                    advisoryURL: catalog?.advisoryURL ?? feedURL,
                    nativeCaskInstallation: native
                ))
            }
        }

        return packages.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
    }

    private func installedHomebrewAppPaths() -> Set<String> {
        guard let brew,
              let result = try? runner.run(
                brew,
                ["info", "--json=v2", "--installed"],
                options: CommandRunOptions(environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
              ), result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [] }

        return Set(casks.flatMap { cask -> [String] in
            guard let artifacts = cask["artifacts"] as? [[String: Any]] else { return [] }
            return artifacts.compactMap { artifact in
                guard let app = artifact["app"] as? [Any], let name = app.first as? String else { return nil }
                let target = artifact["target"] as? String ?? "/Applications/\(name)"
                return URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.path
            }
        })
    }

    private func isInsideSetapp(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathComponents.contains("Setapp")
    }

    private func check(
        _ package: ManagedPackage,
        database: PackageDatabase,
        cached: MacAppVersionCacheRecord?,
        ignoresCache: Bool,
        nativeEnabled: Bool
    ) async -> MacAppCheckResult {
        let catalog = package.bundleIdentifier.flatMap(database.app)
        let automaticManagement = nativeEnabled && PackageActions.canAdopt(package)
        if !automaticManagement, !ignoresCache, let cached, (package.nativeCaskInstallation == nil || cached.source == .homebrewCask), now().timeIntervalSince(cached.checkedAt) < Self.cacheLifetime {
            return MacAppCheckResult(package: package.applying(cached, catalog: catalog), record: cached)
        }

        do {
            let record = try await freshVersion(for: package, catalog: catalog, nativeEnabled: nativeEnabled)
            return MacAppCheckResult(
                package: package.applying(record ?? cached, catalog: catalog),
                record: record ?? cached
            )
        } catch {
            if automaticManagement { return MacAppCheckResult(package: package, record: nil) }
            return MacAppCheckResult(package: package.applying(cached, catalog: catalog), record: cached)
        }
    }

    private func freshVersion(
        for package: ManagedPackage,
        catalog: MacAppCatalogEntry?,
        nativeEnabled: Bool
    ) async throws -> MacAppVersionCacheRecord? {
        if package.nativeCaskInstallation != nil || (nativeEnabled && PackageActions.canAdopt(package)),
           let token = NativeCaskManager.token(for: package) {
            let recipe = try await (nativeManager ?? NativeCaskManager(session: session)).recipe(for: token)
            return MacAppVersionCacheRecord(displayVersion: recipe.version, comparisonVersion: recipe.version,
                source: .homebrewCask, advisoryURL: package.advisoryURL, checkedAt: now())
        }
        switch package.appProvenance {
        case .appStore:
            guard let appStoreID = catalog?.appStoreID ?? appStoreID(for: package) else { return nil }
            return try await appStoreVersion(id: appStoreID)
        case .setapp:
            return nil
        case .direct, .unknown:
            if catalog?.versionSource != .homebrewCask,
               let feed = catalog?.feedURL ?? sparkleFeedURL(for: package),
               let url = safeRemoteURL(feed),
               let record = try? await sparkleVersion(url: url, channel: catalog?.channel) {
                return record
            }
            guard let version = catalog?.version,
                  numericVersionComparison(package.installedVersion, version) != nil else { return nil }
            return MacAppVersionCacheRecord(
                displayVersion: version,
                comparisonVersion: version,
                source: .homebrewCask,
                advisoryURL: catalog?.advisoryURL ?? catalog?.homepage,
                checkedAt: now()
            )
        case .homebrew, .none:
            return nil
        }
    }

    private func appStoreID(for package: ManagedPackage) -> Int? {
        guard let path = package.installLocation,
              let result = try? runner.run(mdls, ["-raw", "-name", "kMDItemAppStoreAdamID", path]),
              result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func sparkleFeedURL(for package: ManagedPackage) -> String? {
        guard let path = package.installLocation,
              let info = infoDictionary(for: URL(fileURLWithPath: path)) else { return nil }
        return nonEmpty(info["SUFeedURL"] as? String)
    }

    private func appStoreVersion(id: Int) async throws -> MacAppVersionCacheRecord? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: storefrontCountry),
        ]
        let data = try await fetch(components.url!, maximumBytes: 1_000_000)
        let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        guard let app = response.results.first else { return nil }
        return MacAppVersionCacheRecord(
            displayVersion: app.version,
            comparisonVersion: app.version,
            source: .appStore,
            advisoryURL: app.trackViewURL,
            checkedAt: now()
        )
    }

    private func sparkleVersion(url: URL, channel: String?) async throws -> MacAppVersionCacheRecord? {
        let data = try await fetch(url, maximumBytes: 5_000_000)
        let parser = SparkleAppcastParser()
        guard parser.parse(data) else { return nil }
        let candidates = parser.items.filter { item in
            item.channel == nil || item.channel == channel
        }
        guard let latest = candidates.compactMap({ item -> SparkleAppcastItem? in
            guard numericVersionComparison(item.version, item.version) != nil else { return nil }
            return item
        }).max(by: {
            numericVersionComparison($0.version, $1.version) == .orderedAscending
        }) else { return nil }

        return MacAppVersionCacheRecord(
            displayVersion: latest.shortVersion ?? latest.version,
            comparisonVersion: latest.version,
            source: .sparkle,
            advisoryURL: latest.infoURL,
            checkedAt: now()
        )
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard safeRemoteURL(url.absoluteString) != nil else { throw MacAppScanError.unsafeURL }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.setValue("PMM/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              safeRemoteURL(http.url?.absoluteString ?? "") != nil,
              http.expectedContentLength <= 0 || http.expectedContentLength <= Int64(maximumBytes) else {
            throw MacAppScanError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw MacAppScanError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

private func infoDictionary(for appURL: URL) -> [String: Any]? {
    let url = appURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
}

private enum MacAppScanError: Error {
    case unsafeURL
    case invalidResponse
    case responseTooLarge
}

struct MacAppVersionCache: Codable {
    var records: [String: MacAppVersionCacheRecord] = [:]

    static func load(from url: URL) -> MacAppVersionCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(MacAppVersionCache.self, from: data) else { return MacAppVersionCache() }
        return cache
    }

    func save(to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct MacAppVersionCacheRecord: Codable, Sendable {
    let displayVersion: String
    let comparisonVersion: String
    let source: MacAppVersionSource
    let advisoryURL: String?
    let checkedAt: Date
}

private struct MacAppCheckResult: Sendable {
    let package: ManagedPackage
    let record: MacAppVersionCacheRecord?
}

private extension ManagedPackage {
    func applying(_ record: MacAppVersionCacheRecord?, catalog: MacAppCatalogEntry?) -> ManagedPackage {
        guard let record else { return self }
        let installedComparison = record.source == .sparkle ? bundleVersion : installedVersion
        let isNewer = record.source == .homebrewCask && PackageActions.usesNativeManagement(self)
            ? NativeCaskManager.isNewer(record.comparisonVersion, than: installedComparison ?? "")
            : numericVersionComparison(installedComparison, record.comparisonVersion) == .orderedAscending
        let latest = isNewer
            ? record.displayVersion
            : nil
        return ManagedPackage(
            manager: manager,
            identifier: identifier,
            catalogIdentifier: catalogIdentifier,
            displayName: displayName,
            installedVersion: installedVersion,
            installedVersions: installedVersions,
            latestVersion: latest,
            summary: summary ?? catalog?.summary,
            category: category ?? catalog?.category,
            homepage: homepage ?? catalog?.homepage,
            docs: docs,
            repo: repo,
            lastUpdatedAt: lastUpdatedAt,
            pulseKind: pulseKind,
            installLocation: installLocation,
            binaryPath: binaryPath,
            executableNames: executableNames,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            appProvenance: appProvenance,
            versionSource: record.source,
            advisoryURL: record.advisoryURL ?? advisoryURL ?? catalog?.advisoryURL,
            versionCheckedAt: record.checkedAt,
            nativeCaskInstallation: nativeCaskInstallation
        )
    }

}

func numericVersionComparison(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
    guard let lhs, let rhs else { return nil }
    let left = numericVersionComponents(lhs)
    let right = numericVersionComponents(rhs)
    guard let left, let right else { return nil }
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : "0"
        let b = index < right.count ? right[index] : "0"
        if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
        if a != b { return a < b ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

private func numericVersionComponents(_ value: String) -> [String]? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
    return components.map {
        let trimmed = $0.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

private func safeRemoteURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), host.contains("."),
          host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
          !host.hasSuffix(".lan"), !host.hasSuffix(".home"), !isPrivateIPAddress(host) else { return nil }
    return url
}

private func isPrivateIPAddress(_ host: String) -> Bool {
    let parts = host.split(separator: ".").compactMap { UInt8($0) }
    if parts.count == 4 {
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }
    return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let version: String
    let trackViewURL: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case trackViewURL = "trackViewUrl"
    }
}

struct SparkleAppcastItem: Equatable {
    var version = ""
    var shortVersion: String?
    var channel: String?
    var infoURL: String?
}

final class SparkleAppcastParser: NSObject, XMLParserDelegate {
    private(set) var items = [SparkleAppcastItem]()
    private var item: SparkleAppcastItem?
    private var element = ""
    private var text = ""

    func parse(_ data: Data) -> Bool {
        items = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName
        text = ""
        if elementName == "item" { item = SparkleAppcastItem() }
        guard var item, elementName == "enclosure" else { return }
        item.version = attributeDict["sparkle:version"] ?? item.version
        item.shortVersion = attributeDict["sparkle:shortVersionString"] ?? item.shortVersion
        item.infoURL = attributeDict["url"] ?? item.infoURL
        self.item = item
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = nonEmpty(text)
        if var item {
            switch elementName {
            case "sparkle:version": item.version = value ?? ""
            case "sparkle:shortVersionString": item.shortVersion = value
            case "sparkle:channel": item.channel = value
            case "sparkle:releaseNotesLink", "link": item.infoURL = value ?? item.infoURL
            case "item":
                if !item.version.isEmpty { items.append(item) }
                self.item = nil
                element = ""
                text = ""
                return
            default: break
            }
            self.item = item
        }
        element = ""
        text = ""
    }
}
