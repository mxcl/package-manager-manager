import Foundation

public struct PackageDatabase: Sendable {
    public static let url = URL(string: "https://www.automicvault.com/db.json")!

    private let formulas: [String: PackageMetadata]
    private let casks: [String: PackageMetadata]
    private let appCasks: Set<String>
    private let crates: [String: PackageMetadata]
    private let npms: [String: PackageMetadata]
    private let apps: [String: MacAppCatalogEntry]

    public init(
        formulas: [String: PackageMetadata] = [:],
        casks: [String: PackageMetadata] = [:],
        appCasks: Set<String> = [],
        crates: [String: PackageMetadata] = [:],
        npms: [String: PackageMetadata] = [:],
        apps: [String: MacAppCatalogEntry] = [:]
    ) {
        self.formulas = formulas
        self.casks = casks
        self.appCasks = appCasks
        self.crates = crates
        self.npms = npms
        self.apps = apps
    }

    public static func load(from url: URL = Self.url) async -> PackageDatabase {
        (try? await fetch(from: url)) ?? cached(from: url) ?? bundled() ?? PackageDatabase()
    }

    public static func fetch(from url: URL = Self.url) async throws -> PackageDatabase {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decode(data)
    }

    public static func cached(from url: URL = Self.url, cache: URLCache = .shared) -> PackageDatabase? {
        let request = URLRequest(url: url)
        guard let data = cache.cachedResponse(for: request)?.data else { return nil }
        return try? decode(data)
    }

    public static func bundled(in bundle: Bundle = .main) -> PackageDatabase? {
        bundled(at: bundle.url(forResource: "db", withExtension: "json"))
    }

    static func bundled(at url: URL?) -> PackageDatabase? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    public static func decode(_ data: Data) throws -> PackageDatabase {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sources = root?["sources"] as? [String: Any]
        let db = sources?["db"] as? [String: Any]
        return PackageDatabase(
            formulas: decodeMetadataMap(db?["formulas"]),
            casks: decodeMetadataMap(db?["casks"]),
            appCasks: decodeAppCasks(db?["casks"]),
            crates: decodeMetadataMap(db?["crates"]),
            npms: decodeMetadataMap(db?["npms"]),
            apps: decodeAppMap(db?["apps"])
        )
    }

    public var catalogPackages: [ManagedPackage] {
        catalogPackages(homebrewPrefix: nil)
    }

    public func catalogPackages(homebrewPrefix: String?) -> [ManagedPackage] {
        let packages = (
            managedPackages(for: .cargoInstall, identifierPrefix: "cargo", metadata: crates) +
            managedPackages(for: .homebrew, identifierPrefix: "brew", metadata: formulas, homebrewPrefix: homebrewPrefix) +
            managedPackages(for: .homebrew, identifierPrefix: "brew:cask", metadata: casks, homebrewPrefix: homebrewPrefix, appNames: appCasks) +
            managedPackages(for: .npm, identifierPrefix: "npm", metadata: npms)
        )
        return Dictionary(grouping: packages, by: \.id).compactMap { $0.value.first }
            .sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                let displayOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
                return $0.identifier < $1.identifier
            }
    }

    public func metadata(for manager: PackageManagerKind, name: String) -> PackageMetadata? {
        switch manager {
        case .cargoInstall:
            return crates[name]
        case .apk, .apt, .dnf, .zypper, .macApp, .rustup, .mise, .skills:
            return nil
        case .homebrew:
            return formulas[name] ?? casks[name]
        case .npm, .npx:
            return npms[name]
        case .uv, .uvx:
            return nil
        }
    }

    public func app(for bundleIdentifier: String) -> MacAppCatalogEntry? {
        guard var entry = apps[bundleIdentifier] else { return nil }
        if let cask = entry.cask, let caskMetadata = casks[cask] {
            entry = entry.applyingFallback(caskMetadata)
        }
        return entry
    }

    private static func decodeAppMap(_ value: Any?) -> [String: MacAppCatalogEntry] {
        guard let map = value as? [String: Any] else { return [:] }
        return map.reduce(into: [:]) { result, pair in
            guard let raw = pair.value as? [String: Any] else { return }
            result[pair.key] = MacAppCatalogEntry(
                bundleIdentifier: pair.key,
                cask: nonEmptyString(raw["cask"]),
                feedURL: nonEmptyString(raw["feed_url"]) ?? nonEmptyString(raw["feedURL"]),
                appStoreID: integer(raw["app_store_id"]),
                channel: nonEmptyString(raw["channel"]),
                versionSource: nonEmptyString(raw["version_source"]) == "cask" ? .homebrewCask : nil,
                advisoryURL: nonEmptyString(raw["advisory_url"]) ?? nonEmptyString(raw["download_url"]),
                summary: nonEmptyString(raw["summary"]),
                category: nonEmptyString(raw["category"]),
                homepage: nonEmptyString(raw["homepage"]),
                version: nonEmptyString(raw["version"])
            )
        }
    }

    private static func decodeMetadataMap(_ value: Any?) -> [String: PackageMetadata] {
        guard let map = value as? [String: Any] else { return [:] }
        return map.reduce(into: [:]) { result, pair in
            guard let raw = pair.value as? [String: Any] else { return }
            result[pair.key] = PackageMetadata(
                displayName: nonEmptyString(raw["displayName"]),
                summary: nonEmptyString(raw["summary"]),
                category: raw["category"] as? String,
                homepage: nonEmptyString(raw["homepage"]),
                docs: docsURL(raw),
                repo: nonEmptyString(raw["repository"]) ?? nonEmptyString(raw["repo"]),
                version: nonEmptyString(raw["version"]),
                lastUpdatedAt: raw["last_updated_at"] as? String,
                pulseKind: raw["pulse_kind"] as? String
            )
        }
    }

    private static func decodeAppCasks(_ value: Any?) -> Set<String> {
        guard let map = value as? [String: Any] else { return [] }
        return Set(map.compactMap { name, value in
            guard let raw = value as? [String: Any], (raw["applications"] as? [Any])?.isEmpty == false else { return nil }
            return name
        })
    }

    private func managedPackages(
        for manager: PackageManagerKind,
        identifierPrefix: String,
        metadata: [String: PackageMetadata],
        homebrewPrefix: String? = nil,
        appNames: Set<String> = []
    ) -> [ManagedPackage] {
        metadata.map { name, metadata in
            ManagedPackage(
                manager: manager,
                identifier: "\(identifierPrefix):\(name)",
                displayName: metadata.displayName ?? name,
                installedVersion: nil,
                latestVersion: metadata.version,
                summary: metadata.summary,
                category: metadata.category,
                homepage: metadata.homepage,
                docs: metadata.docs,
                repo: metadata.repo,
                lastUpdatedAt: metadata.lastUpdatedAt,
                pulseKind: metadata.pulseKind,
                installLocation: homebrewInstallLocation(prefix: homebrewPrefix, identifierPrefix: identifierPrefix, name: name, version: metadata.version),
                appProvenance: appNames.contains(name) ? .homebrew : nil
            )
        }
    }
}

private func homebrewInstallLocation(prefix: String?, identifierPrefix: String, name: String, version: String?) -> String? {
    guard let prefix, identifierPrefix.hasPrefix("brew") else { return nil }
    if identifierPrefix == "brew:cask" {
        return [prefix, "Caskroom", name, version].compactMap { $0 }.joined(separator: "/")
    }
    return "\(prefix)/opt/\(name)"
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
}

private func integer(_ value: Any?) -> Int? {
    value as? Int ?? (value as? String).flatMap(Int.init)
}

private func docsURL(_ raw: [String: Any]) -> String? {
    nonEmptyString(raw["docs"])
        ?? nonEmptyString(raw["upstreamDocs"])
        ?? (raw["docs"] as? [String])?.first(where: { !$0.isEmpty })
}
