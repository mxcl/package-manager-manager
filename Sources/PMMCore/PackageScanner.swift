import Foundation

public enum PackageScanMode: Sendable {
    case local
    case fresh
}

public struct PackageManagerScanResult: Sendable {
    public let manager: PackageManagerKind
    public let packages: [ManagedPackage]
    public let errors: [String]

    public init(manager: PackageManagerKind, packages: [ManagedPackage], errors: [String] = []) {
        self.manager = manager
        self.packages = packages
        self.errors = errors
    }
}

// FileManager is only used for concurrent, read-only filesystem inspection.
public struct PackageScanner: @unchecked Sendable {
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let toolPaths: [String: String]
    private let environment: [String: String]

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolPaths: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.toolPaths = toolPaths
        self.environment = environment
    }

    public func inventory(database: PackageDatabase) async -> PackageInventory {
        let generatedAt = Date()
        var errorsByManager: [PackageManagerKind: [String]] = [:]
        var packages: [ManagedPackage] = []
        for await result in results(for: Set(PackageManagerKind.allCases), database: database, mode: .fresh) {
            packages += result.packages
            errorsByManager[result.manager] = result.errors
        }

        return PackageInventory(
            generatedAt: generatedAt,
            packages: packages.sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return packageDisplayOrder($0, $1)
            },
            errors: PackageManagerKind.allCases.flatMap { errorsByManager[$0] ?? [] }
        )
    }

    public func results(
        for managers: Set<PackageManagerKind>,
        database: PackageDatabase,
        mode: PackageScanMode
    ) -> AsyncStream<PackageManagerScanResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: PackageManagerScanResult.self) { group in
                    for manager in managers {
                        group.addTask {
                            await scanOnUtilityQueue(manager, database: database, mode: mode)
                        }
                    }
                    for await result in group {
                        guard !Task.isCancelled else { break }
                        continuation.yield(result)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func scanCargoInstall(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let cargo = executable(named: "cargo", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
        let result = try runner.run(cargo, ["install", "--list", "--color", "never"])
        guard result.status == 0 else { return [] }
        return parseCargoInstallList(result.stdout)
    }

    public func scanRustup(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let rustup = executable(named: "rustup", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
        let rustupPackage = rustupPackage(rustup)
        let result = try runner.run(rustup, ["toolchain", "list", "-v"])
        guard result.status == 0 else { return [rustupPackage] }
        return [rustupPackage] + result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            rustupToolchain(String(line), rustup: rustup)
        }
    }

    public func scanHomebrew(database: PackageDatabase) throws -> [ManagedPackage] {
        try scanHomebrew(database: database, mode: .fresh)
    }

    private func scanHomebrew(database: PackageDatabase, mode: PackageScanMode) throws -> [ManagedPackage] {
        guard let brew = executable(named: "brew", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin"]) else { return [] }
        let outdated: (formulae: [String: String], casks: [String: String]) = mode == .fresh
            ? try homebrewOutdated(brew)
            : ([:], [:])
        let prefix = successfulBrewLine(brew, ["--prefix"])
        let result = try runBrew(brew, ["info", "--json=v2", "--installed"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let binaries = homebrewFormulaBinaryPaths(prefix: prefix)
        return homebrewInstalledFormulae(raw["formulae"], outdated: outdated.formulae, binaries: binaries, prefix: prefix, database: database)
            + homebrewInstalledCasks(raw["casks"], outdated: outdated.casks, prefix: prefix, database: database)
    }

    public func homebrewPrefix() -> String? {
        guard let brew = executable(named: "brew", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin"]) else { return nil }
        return successfulBrewLine(brew, ["--prefix"])
    }

    public func scanNPM(database: PackageDatabase) throws -> [ManagedPackage] {
        try scanNPM(database: database, mode: .fresh)
    }

    private func scanNPM(database: PackageDatabase, mode: PackageScanMode) throws -> [ManagedPackage] {
        guard let npm = executable(named: "npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
        let root = successfulLine(npm, ["root", "-g"])
        let prefix = successfulLine(npm, ["prefix", "-g"])
        let bin = prefix.map { "\($0)/bin" }
        let outdated = mode == .fresh ? npmOutdated(npm) : [:]
        let result = try runner.run(npm, ["ls", "-g", "--depth=0", "--json"])
        guard let json = jsonObject(result.stdout),
              let dependencies = json["dependencies"] as? [String: Any] else { return [] }

        return dependencies.compactMap { name, raw in
            guard let body = raw as? [String: Any] else { return nil }
            let version = body["version"] as? String
            let curation = database.metadata(for: .npm, name: name)
            let installLocation = root.map { "\($0)/\(name)" }
            let package = installLocation.flatMap { readPackageJSON(URL(fileURLWithPath: $0).appendingPathComponent("package.json")) }
            return ManagedPackage(
                manager: .npm,
                identifier: "npm:\(name)",
                displayName: name,
                installedVersion: version,
                latestVersion: outdated[name],
                summary: package?.summary,
                category: curation?.category,
                homepage: package?.homepage,
                docs: nil,
                repo: package?.repo,
                lastUpdatedAt: curation?.lastUpdatedAt,
                pulseKind: curation?.pulseKind,
                installLocation: installLocation,
                binaryPath: npmBinaryPath(packageName: name, root: root, bin: bin)
            )
        }
    }

    public func scanNPX(database: PackageDatabase) throws -> [ManagedPackage] {
        let cache = homeDirectory.appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let cacheEntries = try? fileManager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else {
            return []
        }

        let packages = cacheEntries.flatMap { entry -> [ManagedPackage] in
            let modules = entry.appendingPathComponent("node_modules", isDirectory: true)
            guard let allNames = try? fileManager.contentsOfDirectory(atPath: modules.path) else { return [] }
            let names = npxRequestedPackageNames(in: entry) ?? allNames
            return names.flatMap { packageNames(in: modules, name: $0) }.compactMap { packageURL in
                guard let package = readPackageJSON(packageURL.appendingPathComponent("package.json")) else { return nil }
                let name = package.name
                let curation = database.metadata(for: .npx, name: name)
                return ManagedPackage(
                    manager: .npx,
                    identifier: "npx:\(name)",
                    displayName: name,
                    installedVersion: package.version,
                    latestVersion: nil,
                    summary: package.summary,
                    category: curation?.category,
                    homepage: package.homepage,
                    docs: nil,
                    repo: package.repo,
                    lastUpdatedAt: curation?.lastUpdatedAt,
                    pulseKind: curation?.pulseKind,
                    installLocation: packageURL.path,
                    binaryPath: nil
                )
            }
        }
        return ManagedPackage.consolidatingInstalledVersions(in: packages)
    }

    public func scanSkills(database: PackageDatabase) throws -> [ManagedPackage] {
        let executable: String
        let prefix: [String]
        if let skills = toolPaths["skills"] {
            executable = skills
            prefix = []
        } else if let npx = toolPaths["npx"] {
            executable = npx
            prefix = ["--yes", "skills"]
        } else if let skills = ["/opt/homebrew/bin/skills", "/usr/local/bin/skills"].first(where: fileManager.isExecutableFile) {
            executable = skills
            prefix = []
        } else if let npx = firstExecutable(named: "npx", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) {
            executable = npx
            prefix = ["--yes", "skills"]
        } else {
            return []
        }
        let project = try runner.run(executable, prefix + ["list"])
        let global = try runner.run(executable, prefix + ["list", "--global"])
        return (project.status == 0 ? parseSkillsList(project.stdout, defaultScope: "project") : [])
            + (global.status == 0 ? parseSkillsList(global.stdout, defaultScope: "global") : [])
    }

    public func scanNPX(database: PackageDatabase, npmRegistryClient: NPMRegistryClient) async throws -> [ManagedPackage] {
        let packages = try scanNPX(database: database)
        let names = Set(packages.map(\.packageToken))
        let resolvedVersions = npxResolvedLatestVersions(for: names)
        let metadata = await withTaskGroup(of: (String, PackageMetadata?).self, returning: [String: PackageMetadata].self) { group in
            for name in names {
                group.addTask {
                    (name, try? await npmRegistryClient.metadata(for: name))
                }
            }
            var metadata: [String: PackageMetadata] = [:]
            for await (name, value) in group {
                metadata[name] = value
            }
            return metadata
        }
        return packages.map { package in
            package.applyingNPXSourceMetadata(metadata[package.packageToken], latestVersion: resolvedVersions[package.packageToken])
        }
    }

    public func scanUV(database: PackageDatabase) throws -> [ManagedPackage] {
        try scanUV(database: database, mode: .fresh)
    }

    private func scanUV(database: PackageDatabase, mode: PackageScanMode) throws -> [ManagedPackage] {
        guard let uv = executable(named: "uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
        let toolDir = successfulLine(uv, ["tool", "dir", "--offline", "--color", "never"])
        let pythonDir = successfulLine(uv, ["python", "dir", "--offline", "--color", "never"])
        return try uvTools(uv, toolDir: toolDir, includeOutdated: mode == .fresh, database: database) + uvPythons(uv, pythonDir: pythonDir)
    }

    public func scanUVX(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let uv = executable(named: "uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]),
              let cacheDir = successfulLine(uv, ["cache", "dir"]) else { return [] }
        let environments = URL(fileURLWithPath: cacheDir).appendingPathComponent("environments-v2", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: environments, includingPropertiesForKeys: nil) else { return [] }

        return entries.flatMap { entry -> [ManagedPackage] in
            guard !entry.lastPathComponent.hasPrefix(".") else { return [] }
            return uvxEnvironmentRoots(entry).compactMap { environment in
                let fallbackName = uvxDisplayName(entry.lastPathComponent)
                let dist = matchingDistInfo(in: environment, packageName: fallbackName) ?? requestedDistInfo(in: environment) ?? singleDistInfo(in: environment)
                guard dist != nil || !isUVXCacheHash(entry.lastPathComponent) else { return nil }
                let name = dist?.name ?? fallbackName
                return ManagedPackage(
                    manager: .uvx,
                    identifier: "uvx:\(name)",
                    displayName: name,
                    installedVersion: dist?.version,
                    latestVersion: nil,
                    summary: dist?.summary ?? "uvx cached tool environment",
                    category: "developer-tools",
                    homepage: dist?.homepage,
                    installLocation: environment.path,
                    binaryPath: uvxBinaryPath(in: environment, preferredName: name)
                )
            }
        }
    }

    private func parseCargoInstallList(_ output: String) -> [ManagedPackage] {
        var packages: [ManagedPackage] = []
        var current: (name: String, version: String, bins: [String])?

        func flush() {
            guard let crate = current else { return }
            packages.append(ManagedPackage(
                manager: .cargoInstall,
                identifier: "cargo:\(crate.name)",
                displayName: crate.name,
                installedVersion: crate.version,
                latestVersion: nil,
                summary: "cargo-installed Rust binary",
                category: "developer-tools",
                installLocation: cargoHome.path,
                binaryPath: crate.bins.first.flatMap(cargoBinaryPath)
            ))
        }

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if let header = cargoInstallHeader(line) {
                flush()
                current = (header.name, header.version, [])
            } else if line.first?.isWhitespace == true {
                let bin = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bin.isEmpty { current?.bins.append(bin) }
            }
        }
        flush()
        return packages
    }

    private func cargoInstallHeader(_ line: String) -> (name: String, version: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(":") else { return nil }
        let parts = trimmed.dropLast().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let version = parts.last, version.hasPrefix("v") else { return nil }
        return (parts.dropLast().joined(separator: " "), String(version.dropFirst()))
    }

    private func rustupPackage(_ rustup: String) -> ManagedPackage {
        ManagedPackage(
            manager: .rustup,
            identifier: "rustup:rustup",
            displayName: "rustup",
            installedVersion: rustupVersion(rustup),
            latestVersion: nil,
            summary: "Rust toolchain installer",
            category: "developer-tools",
            homepage: "https://rustup.rs/",
            docs: "https://rust-lang.github.io/rustup/",
            repo: "https://github.com/rust-lang/rustup",
            installLocation: URL(fileURLWithPath: rustup).deletingLastPathComponent().path,
            binaryPath: rustup
        )
    }

    private func rustupToolchain(_ line: String, rustup: String) -> ManagedPackage? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first else { return nil }
        let installLocation = parts.last?.hasPrefix("/") == true ? parts.last : nil
        let rustc = rustupRustcVersion(rustup: rustup, toolchain: name)
        return ManagedPackage(
            manager: .rustup,
            identifier: "rustup:toolchain:\(name)",
            displayName: name,
            installedVersion: rustc,
            latestVersion: nil,
            summary: "rustup managed Rust toolchain",
            category: "language-runtime",
            homepage: "https://rustup.rs/",
            docs: "https://rust-lang.github.io/rustup/",
            repo: "https://github.com/rust-lang/rustup",
            installLocation: installLocation,
            binaryPath: installLocation.flatMap { rustcBinaryPath(in: $0) }
        )
    }

    private func rustcBinaryPath(in toolchainPath: String) -> String? {
        let path = "\(toolchainPath)/bin/rustc"
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    private func rustupVersion(_ rustup: String) -> String? {
        guard let result = try? runner.run(rustup, ["--version"]),
              result.status == 0 else { return nil }
        let parts = result.stdout.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "rustup", parts.count > 1 else { return nil }
        return parts[1]
    }

    private func rustupRustcVersion(rustup: String, toolchain: String) -> String? {
        guard let result = try? runner.run(rustup, ["run", toolchain, "rustc", "--version"]),
              result.status == 0 else { return nil }
        let parts = result.stdout.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "rustc", parts.count > 1 else { return nil }
        return parts[1]
    }

    private var cargoHome: URL {
        if let value = environment["CARGO_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".cargo", isDirectory: true)
    }

    private func cargoBinaryPath(_ name: String) -> String? {
        let path = cargoHome.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(name).path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    private func homebrewInstalledFormulae(
        _ value: Any?,
        outdated: [String: String],
        binaries: [String: [String]],
        prefix: String?,
        database: PackageDatabase
    ) -> [ManagedPackage] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let installed = item["installed"] as? [[String: Any]] ?? []
            guard installed.contains(where: { ($0["installed_on_request"] as? Bool) == true }),
                  let name = item["name"] as? String else { return nil }
            let version = item["linked_keg"] as? String
                ?? installed.compactMap { $0["version"] as? String }.last
                ?? homebrewVersion(in: item)
            let binaryPaths = binaries[name] ?? []
            let curation = database.metadata(for: .homebrew, name: name)
            let metadata = homebrewMetadata(from: item)
            let cached = homebrewCachedMetadata(name: name, kindFlag: "--formula")
            return ManagedPackage(
                manager: .homebrew,
                identifier: "brew:\(name)",
                displayName: name,
                installedVersion: version,
                latestVersion: outdated[name] ?? (metadata.version == version ? metadata.version : nil),
                summary: metadata.summary ?? cached?.summary,
                category: curation?.category,
                homepage: metadata.homepage ?? cached?.homepage,
                docs: metadata.docs ?? cached?.docs,
                repo: curation?.repo ?? metadata.repo ?? cached?.repo,
                lastUpdatedAt: curation?.lastUpdatedAt,
                pulseKind: curation?.pulseKind,
                installLocation: homebrewInstallLocation(prefix: prefix, kindFlag: "--formula", name: name, version: version),
                binaryPath: binaryPaths.first ?? homebrewBinaryPath(prefix: prefix, name: name),
                executableNames: binaryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
            )
        }
    }

    private func homebrewInstalledCasks(
        _ value: Any?,
        outdated: [String: String],
        prefix: String?,
        database: PackageDatabase
    ) -> [ManagedPackage] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["token"] as? String ?? item["name"] as? String else { return nil }
            let infoMetadata = homebrewMetadata(from: item)
            let cachedMetadata = homebrewCachedMetadata(name: name, kindFlag: "--cask")
            let curation = database.metadata(for: .homebrew, name: name)
            let version = infoMetadata.version ?? cachedMetadata?.version
            return ManagedPackage(
                manager: .homebrew,
                identifier: "brew:cask:\(name)",
                displayName: name,
                installedVersion: version,
                latestVersion: outdated[name] ?? (cachedMetadata?.version == version ? cachedMetadata?.version : infoMetadata.version),
                summary: infoMetadata.summary ?? cachedMetadata?.summary,
                category: curation?.category,
                homepage: infoMetadata.homepage ?? cachedMetadata?.homepage,
                docs: infoMetadata.docs ?? cachedMetadata?.docs,
                repo: curation?.repo ?? infoMetadata.repo ?? cachedMetadata?.repo,
                lastUpdatedAt: curation?.lastUpdatedAt,
                pulseKind: curation?.pulseKind,
                installLocation: homebrewInstallLocation(prefix: prefix, kindFlag: "--cask", name: name, version: version),
                binaryPath: homebrewCaskBinaryPath(item) ?? homebrewBinaryPath(prefix: prefix, name: name)
            )
        }
    }

    private func homebrewFormulaBinaryPaths(prefix: String?) -> [String: [String]] {
        guard let prefix,
              let entries = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: prefix).appendingPathComponent("bin", isDirectory: true),
                includingPropertiesForKeys: nil
              ) else { return [:] }
        return entries.reduce(into: [:]) { paths, entry in
            let resolved = entry.resolvingSymlinksInPath().path
            guard let name = homebrewFormulaName(in: resolved) else { return }
            paths[name, default: []].append(resolved)
            paths[name]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func homebrewFormulaName(in path: String) -> String? {
        guard let cellar = path.range(of: "/Cellar/")?.upperBound else { return nil }
        return path[cellar...].split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    private func homebrewInstallLocation(prefix: String?, kindFlag: String, name: String, version: String?) -> String? {
        guard let prefix else { return nil }
        if kindFlag == "--cask", let version {
            return "\(prefix)/Caskroom/\(name)/\(version)"
        }
        return "\(prefix)/opt/\(name)"
    }

    private func homebrewBinaryPath(prefix: String?, name: String) -> String? {
        guard let prefix else { return nil }
        let path = "\(prefix)/bin/\(name)"
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    private func homebrewCaskBinaryPath(_ item: [String: Any]) -> String? {
        guard let artifacts = item["artifacts"] as? [[String: Any]] else { return nil }
        for artifact in artifacts {
            if artifact["binary"] != nil, let target = artifact["target"] as? String {
                return target
            }
            if let binary = artifact["binary"] as? [Any],
               let options = binary.first(where: { $0 is [String: Any] }) as? [String: Any],
               let target = options["target"] as? String {
                return target
            }
        }
        return nil
    }

    private func homebrewCachedMetadata(name: String, kindFlag: String) -> PackageMetadata? {
        let kind = kindFlag == "--cask" ? "cask" : "formula"
        for cache in homebrewCacheURLs {
            let item = cache.appendingPathComponent("api", isDirectory: true)
                .appendingPathComponent(kind, isDirectory: true)
                .appendingPathComponent("\(name).json")
            if let metadata = homebrewMetadata(from: item) {
                return metadata
            }
        }
        for cache in homebrewCacheURLs {
            for item in homebrewAggregateCacheURLs(cache: cache, kind: kind) {
                if let metadata = homebrewMetadata(named: name, from: item) {
                    return metadata
                }
            }
        }
        return nil
    }

    private var homebrewCacheURLs: [URL] {
        var urls: [URL] = []
        if let cache = environment["HOMEBREW_CACHE"], !cache.isEmpty {
            urls.append(URL(fileURLWithPath: cache, isDirectory: true))
        }
        urls.append(homeDirectory.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true))
        return urls
    }

    private func homebrewAggregateCacheURLs(cache: URL, kind: String) -> [URL] {
        let plural = kind == "formula" ? "formulae" : "casks"
        let api = cache.appendingPathComponent("api", isDirectory: true)
        return [
            api.appendingPathComponent("\(kind).json"),
            api.appendingPathComponent("\(plural).json"),
            cache.appendingPathComponent("\(kind).json"),
            cache.appendingPathComponent("\(plural).json"),
        ]
    }

    private func homebrewMetadata(from url: URL) -> PackageMetadata? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return homebrewMetadata(from: raw)
    }

    private func homebrewMetadata(named name: String, from url: URL) -> PackageMetadata? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let array = raw as? [[String: Any]] {
            return array.first { ($0["name"] as? String) == name || ($0["token"] as? String) == name }.flatMap(homebrewMetadata)
        }
        if let map = raw as? [String: Any],
           let item = map[name] as? [String: Any] {
            return homebrewMetadata(from: item)
        }
        return nil
    }

    private func homebrewMetadata(from raw: [String: Any]) -> PackageMetadata {
        let sourceURL = (raw["urls"] as? [String: Any])
            .flatMap { $0["head"] as? [String: Any] ?? $0["stable"] as? [String: Any] }?["url"] as? String
        return PackageMetadata(
            summary: raw["desc"] as? String,
            category: nil,
            homepage: raw["homepage"] as? String,
            repo: sourceRepositoryURL(sourceURL),
            version: homebrewVersion(in: raw)
        )
    }

    private func homebrewVersion(in raw: [String: Any]) -> String? {
        if let version = raw["linked_keg"] as? String {
            return version
        }
        if let version = raw["version"] as? String {
            return version
        }
        return (raw["versions"] as? [String: Any])?["stable"] as? String
    }

    private func homebrewOutdated(_ brew: String) throws -> (formulae: [String: String], casks: [String: String]) {
        let result = try runBrew(brew, ["outdated", "--json=v2"])
        guard let json = jsonObject(result.stdout) else { return ([:], [:]) }
        return (
            outdatedMap(json["formulae"]),
            outdatedMap(json["casks"])
        )
    }

    private func npmOutdated(_ npm: String) -> [String: String] {
        guard let json = try? runner.run(npm, ["outdated", "-g", "--json"]).stdout,
              let object = jsonObject(json) else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            guard let body = pair.value as? [String: Any],
                  let latest = body["latest"] as? String ?? body["wanted"] as? String else { return }
            result[pair.key] = latest
        }
    }

    private func uvTools(_ uv: String, toolDir: String?, includeOutdated: Bool, database: PackageDatabase) throws -> [ManagedPackage] {
        let result = try runner.run(uv, ["tool", "list", "--show-paths", "--show-version-specifiers", "--show-python", "--offline", "--color", "never"])
        guard result.status == 0 else { return [] }
        return parseUVToolList(result.stdout, toolDir: toolDir, outdated: includeOutdated ? uvToolOutdated(uv) : [:], database: database)
    }

    private func uvPythons(_ uv: String, pythonDir: String?) throws -> [ManagedPackage] {
        guard let pythonDir else { return [] }
        let latest = uvPythonLatestVersions(uv)
        let result = try runner.run(uv, ["python", "list", "--only-installed", "--output-format", "json", "--offline", "--color", "never"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let packages: [ManagedPackage] = rows.compactMap { row in
            guard let path = row["path"] as? String,
                  path == pythonDir || path.hasPrefix("\(pythonDir)/"),
                  let identity = uvPythonIdentity(row),
                  let version = row["version"] as? String else { return nil }
            let latestVersion = uvPythonKey(row).flatMap { latest[$0] }.flatMap { $0 == version ? nil : $0 }
            return ManagedPackage(
                manager: .uv,
                identifier: identity.identifier,
                displayName: identity.displayName,
                installedVersion: version,
                latestVersion: latestVersion,
                summary: "uv-managed Python",
                category: "language-runtime",
                installLocation: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                binaryPath: path
            )
        }
        return ManagedPackage.consolidatingInstalledVersions(in: packages)
    }

    private func uvToolOutdated(_ uv: String) -> [String: String] {
        guard let result = try? runner.run(uv, ["tool", "list", "--outdated", "--show-paths", "--show-version-specifiers", "--show-python", "--color", "never"]),
              result.status == 0 else { return [:] }
        return parseUVToolLatestMap(result.stdout)
    }

    private func uvPythonLatestVersions(_ uv: String) -> [String: String] {
        guard let result = try? runner.run(uv, ["python", "list", "--all-versions", "--only-downloads", "--output-format", "json", "--offline", "--color", "never"]),
              result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        return rows.reduce(into: [:]) { latest, row in
            guard let key = uvPythonKey(row), let version = row["version"] as? String else { return }
            if latest[key].map({ version.localizedStandardCompare($0) == .orderedDescending }) ?? true {
                latest[key] = version
            }
        }
    }

    private func parseUVToolList(_ output: String, toolDir: String?, outdated: [String: String], database: PackageDatabase) -> [ManagedPackage] {
        var packages: [ManagedPackage] = []
        var current: (name: String, version: String?, latest: String?, lines: [String])?

        func flush() {
            guard let tool = current else { return }
            let paths = tool.lines.compactMap(absolutePath)
            let installLocation = paths.first { path in
                guard let toolDir else { return false }
                return path == toolDir || path.hasPrefix("\(toolDir)/")
            }
            let binaryPath = paths.first { fileManager.fileExists(atPath: $0) && !fileManager.directoryExists(atPath: $0) }
            let metadata = database.metadata(for: .uv, name: tool.name)
            packages.append(ManagedPackage(
                manager: .uv,
                identifier: "uv:tool:\(tool.name)",
                displayName: tool.name,
                installedVersion: tool.version,
                latestVersion: tool.latest ?? outdated[tool.name] ?? metadata?.version,
                summary: metadata?.summary ?? "uv-installed tool",
                category: metadata?.category ?? "developer-tools",
                homepage: metadata?.homepage,
                docs: metadata?.docs,
                repo: metadata?.repo,
                lastUpdatedAt: metadata?.lastUpdatedAt,
                pulseKind: metadata?.pulseKind,
                installLocation: installLocation,
                binaryPath: binaryPath
            ))
        }

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if let header = uvToolHeader(line) {
                flush()
                current = (header.name, header.version, header.latest, [])
            } else {
                current?.lines.append(line)
            }
        }
        flush()
        return packages
    }

    private func parseUVToolLatestMap(_ output: String) -> [String: String] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            guard let header = uvToolHeader(String(line)), let latest = header.latest else { return }
            result[header.name] = latest
        }
    }

    private func parseSkillsList(_ output: String, defaultScope: String) -> [ManagedPackage] {
        var scope = defaultScope
        return output
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine)
                if line == "Project Skills" { scope = "project"; return nil }
                if line == "Global Skills" { scope = "global"; return nil }
                guard let nameEnd = line.firstIndex(where: \.isWhitespace),
                      let agents = line.range(of: " Agents:") else { return nil }
                let name = String(line[..<nameEnd])
                let path = line[nameEnd..<agents.lowerBound].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !path.isEmpty else { return nil }
                let expandedPath = path.hasPrefix("~/")
                    ? homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
                    : path
                return ManagedPackage(
                    manager: .skills,
                    identifier: "skills:\(scope):\(name)",
                    displayName: name,
                    installedVersion: "installed",
                    latestVersion: nil,
                    summary: scope == "global" ? "Global agent skill" : "Project agent skill",
                    category: "developer-tools",
                    installLocation: expandedPath
                )
            }
    }

    private func uvToolHeader(_ line: String) -> (name: String, version: String?, latest: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first, !name.hasPrefix("-"), name != "No" else { return nil }
        let version = parts.dropFirst().first { $0.hasPrefix("v") }.map { String($0.dropFirst()) }
        let latest = trimmed.latestVersionMarker
        return (name, version, latest)
    }

    private func absolutePath(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        return String(trimmed[slash...])
    }

    private func uvPythonKey(_ row: [String: Any]) -> String? {
        guard let implementation = row["implementation"] as? String,
              let os = row["os"] as? String,
              let arch = row["arch"] as? String,
              let libc = row["libc"] as? String,
              let variant = row["variant"] as? String,
              let parts = row["version_parts"] as? [String: Any],
              let major = parts["major"] as? Int,
              let minor = parts["minor"] as? Int else { return nil }
        return [implementation, "\(major).\(minor)", os, arch, libc, variant].joined(separator: ":")
    }

    private func uvPythonIdentity(_ row: [String: Any]) -> (identifier: String, displayName: String)? {
        guard let implementation = row["implementation"] as? String,
              let parts = row["version_parts"] as? [String: Any],
              let major = parts["major"] as? Int,
              let minor = parts["minor"] as? Int else { return nil }
        return ("uv:\(implementation):\(major).\(minor)", "uv Managed Python \(major).\(minor)")
    }

    private func successfulLine(_ executable: String, _ arguments: [String]) -> String? {
        guard let result = try? runner.run(executable, arguments), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func successfulBrewLine(_ brew: String, _ arguments: [String]) -> String? {
        guard let result = try? runBrew(brew, arguments), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func runBrew(_ brew: String, _ arguments: [String]) throws -> CommandResult {
        try runner.run(
            brew,
            arguments,
            options: CommandRunOptions(environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        )
    }

    private func successfulLines(_ executable: String, _ arguments: [String]) -> [String]? {
        guard let result = try? runner.run(executable, arguments), result.status == 0 else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func executable(named name: String, extraPaths: [String]) -> String? {
        toolPaths[name] ?? firstExecutable(named: name, extraPaths: extraPaths)
    }

    private func scanOnUtilityQueue(
        _ manager: PackageManagerKind,
        database: PackageDatabase,
        mode: PackageScanMode
    ) async -> PackageManagerScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let packages: [ManagedPackage]
                    switch manager {
                    case .cargoInstall: packages = try scanCargoInstall(database: database)
                    case .rustup: packages = try scanRustup(database: database)
                    case .homebrew: packages = try scanHomebrew(database: database, mode: mode)
                    case .npm: packages = try scanNPM(database: database, mode: mode)
                    case .npx: packages = try scanNPX(database: database)
                    case .skills: packages = try scanSkills(database: database)
                    case .uv: packages = try scanUV(database: database, mode: mode)
                    case .uvx: packages = try scanUVX(database: database)
                    }
                    continuation.resume(returning: PackageManagerScanResult(manager: manager, packages: packages))
                } catch {
                    continuation.resume(returning: PackageManagerScanResult(
                        manager: manager,
                        packages: [],
                        errors: [error.localizedDescription]
                    ))
                }
            }
        }
    }

    private func npxResolvedLatestVersions(for names: Set<String>) -> [String: String] {
        guard !names.isEmpty,
              let npm = executable(named: "npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [:] }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pmm-npx-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temp) }
            try #"{"private":true}"#.write(to: temp.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            let packages = names.sorted().map { "\($0)@latest" }
            let result = try runner.run(npm, ["install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund", "--prefix", temp.path] + packages)
            guard result.status == 0 else { return [:] }
            return npxResolvedVersions(in: temp.appendingPathComponent("package-lock.json"), names: names)
        } catch {
            return [:]
        }
    }

    private func npxResolvedVersions(in packageLock: URL, names: Set<String>) -> [String: String] {
        guard let data = try? Data(contentsOf: packageLock),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String: Any] else { return [:] }
        return names.reduce(into: [:]) { result, name in
            guard let body = packages["node_modules/\(name)"] as? [String: Any]
                    ?? packages.first(where: { $0.key.hasSuffix("/node_modules/\(name)") })?.value as? [String: Any],
                  let version = body["version"] as? String else { return }
            result[name] = version
        }
    }

    private func npmBinaryPath(packageName: String, root: String?, bin: String?) -> String? {
        guard let root, let bin else { return nil }
        let packageURL = URL(fileURLWithPath: root).appendingPathComponent(packageName, isDirectory: true)
        let packageJSON = packageURL.appendingPathComponent("package.json")
        let binNames = npmBinNames(from: packageJSON, fallback: packageName)
        return binNames
            .map { "\(bin)/\($0)" }
            .first { fileManager.fileExists(atPath: $0) }
    }

    private func npmBinNames(from packageJSON: URL, fallback: String) -> [String] {
        guard let data = try? Data(contentsOf: packageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bin = json["bin"] else { return [fallback] }
        if bin is String {
            return [fallback]
        }
        if let bins = bin as? [String: Any] {
            return bins.keys.sorted()
        }
        return [fallback]
    }

    private func packageNames(in modules: URL, name: String) -> [URL] {
        let url = modules.appendingPathComponent(name, isDirectory: true)
        guard name.hasPrefix("@") else { return [url] }
        let scoped = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return scoped
    }

    private func readPackageJSON(_ url: URL) -> PackageJSON? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return PackageJSON(
            name: name,
            version: json["version"] as? String,
            summary: json["description"] as? String,
            homepage: json["homepage"] as? String,
            repo: sourceRepositoryURL(json["repository"])
        )
    }

    private func npxRequestedPackageNames(in entry: URL) -> [String]? {
        packageLockRootDependencyNames(entry.appendingPathComponent("package-lock.json"))
            ?? packageJSONDependencyNames(entry.appendingPathComponent("package.json"))
    }

    private func packageLockRootDependencyNames(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let packages = json["packages"] as? [String: Any],
           let root = packages[""] as? [String: Any],
           let dependencies = root["dependencies"] as? [String: Any] {
            return dependencies.keys.sorted()
        }
        return nil
    }

    private func packageJSONDependencyNames(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let dependencies = json["dependencies"] as? [String: Any] {
            return dependencies.keys.sorted()
        }
        return nil
    }

    private func uvxDisplayName(_ directoryName: String) -> String {
        guard let dash = directoryName.lastIndex(of: "-") else { return directoryName }
        let suffix = directoryName[directoryName.index(after: dash)...]
        guard suffix.count == 16, suffix.allSatisfy(\.isHexDigit) else { return directoryName }
        let prefix = directoryName[..<dash]
        return prefix.isEmpty ? directoryName : String(prefix)
    }

    private func isUVXCacheHash(_ directoryName: String) -> Bool {
        directoryName.count == 16 && directoryName.allSatisfy(\.isHexDigit)
    }

    private func uvxEnvironmentRoots(_ entry: URL) -> [URL] {
        if isPythonEnvironment(entry) {
            return [entry]
        }
        let children = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
        let environments = children.filter(isPythonEnvironment)
        return environments.isEmpty ? [entry] : environments
    }

    private func isPythonEnvironment(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
            || fileManager.directoryExists(atPath: url.appendingPathComponent("lib", isDirectory: true).path)
    }

    private func requestedDistInfo(in environment: URL) -> (name: String, version: String?, summary: String?, homepage: String?)? {
        let requested = distInfos(in: environment).filter { fileManager.fileExists(atPath: $0.appendingPathComponent("REQUESTED").path) }
        guard requested.count == 1 else { return nil }
        return requested.first.flatMap(pythonPackageMetadata)
    }

    private func singleDistInfo(in environment: URL) -> (name: String, version: String?, summary: String?, homepage: String?)? {
        let infos = distInfos(in: environment)
        guard infos.count == 1 else { return nil }
        return infos.first.flatMap(pythonPackageMetadata)
    }

    private func distInfos(in environment: URL) -> [URL] {
        let lib = environment.appendingPathComponent("lib", isDirectory: true)
        guard let pythonDirs = try? fileManager.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil) else { return [] }
        return pythonDirs.flatMap { pythonDir -> [URL] in
            let sitePackages = pythonDir.appendingPathComponent("site-packages", isDirectory: true)
            let entries = (try? fileManager.contentsOfDirectory(at: sitePackages, includingPropertiesForKeys: nil)) ?? []
            return entries.filter { $0.pathExtension == "dist-info" }
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func matchingDistInfo(in environment: URL, packageName: String) -> (name: String, version: String?, summary: String?, homepage: String?)? {
        let normalizedPackage = normalizedPythonPackageName(packageName)
        return distInfos(in: environment).first { entry in
            guard let distName = distInfoNameAndVersion(entry.deletingPathExtension().lastPathComponent)?.name else { return false }
            return normalizedPythonPackageName(distName) == normalizedPackage
        }.flatMap(pythonPackageMetadata)
    }

    private func pythonPackageMetadata(from distInfo: URL) -> (name: String, version: String?, summary: String?, homepage: String?)? {
        let stem = distInfo.deletingPathExtension().lastPathComponent
        let nameAndVersion = distInfoNameAndVersion(stem)
        let fields = metadataFields(distInfo.appendingPathComponent("METADATA"))
        guard let name = fields["Name"] ?? nameAndVersion?.name else { return nil }
        return (
            name,
            fields["Version"] ?? nameAndVersion?.version,
            fields["Summary"],
            fields["Home-page"] ?? projectURL(named: "Homepage", in: fields)
        )
    }

    private func metadataFields(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: [:]) { fields, line in
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
    }

    private func projectURL(named label: String, in fields: [String: String]) -> String? {
        guard let value = fields["Project-URL"] else { return nil }
        let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].localizedCaseInsensitiveCompare(label) == .orderedSame else { return nil }
        return parts[1]
    }

    private func distInfoNameAndVersion(_ stem: String) -> (name: String, version: String?)? {
        guard let dash = stem.lastIndex(of: "-") else { return (stem, nil) }
        return (String(stem[..<dash]), String(stem[stem.index(after: dash)...]))
    }

    private func normalizedPythonPackageName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func uvxBinaryPath(in environment: URL, preferredName: String) -> String? {
        let bin = environment.appendingPathComponent("bin", isDirectory: true)
        let preferred = bin.appendingPathComponent(preferredName)
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred.path
        }
        guard let entries = try? fileManager.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil) else { return nil }
        let skipped = Set(["activate", "activate.bat", "activate.csh", "activate.fish", "activate.nu", "activate.ps1", "activate_this.py", "deactivate.bat", "python", "python3", "pydoc.bat"])
        return entries
            .filter { !skipped.contains($0.lastPathComponent) && fileManager.isExecutableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first?
            .path
    }

}

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func packageDisplayOrder(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
    let displayOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
    if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
    return lhs.identifier < rhs.identifier
}

private func outdatedMap(_ value: Any?) -> [String: String] {
    guard let array = value as? [[String: Any]] else { return [:] }
    return array.reduce(into: [:]) { result, item in
        guard let name = item["name"] as? String,
              let newest = item["current_version"] as? String else { return }
        for key in [name, name.split(separator: "/").last.map(String.init)].compactMap({ $0 }) {
            result[key] = newest
        }
    }
}

private struct PackageJSON {
    let name: String
    let version: String?
    let summary: String?
    let homepage: String?
    let repo: String?
}

private extension ManagedPackage {
    func applyingNPXSourceMetadata(_ metadata: PackageMetadata?, latestVersion: String?) -> ManagedPackage {
        ManagedPackage(
            manager: manager,
            identifier: identifier,
            displayName: displayName,
            installedVersion: installedVersion,
            installedVersions: installedVersions,
            latestVersion: latestVersion,
            summary: summary ?? metadata?.summary,
            category: category,
            homepage: homepage ?? metadata?.homepage,
            docs: docs ?? metadata?.docs,
            repo: repo ?? metadata?.repo,
            lastUpdatedAt: lastUpdatedAt,
            pulseKind: pulseKind,
            installLocation: installLocation,
            binaryPath: binaryPath
        )
    }
}

private func sourceRepositoryURL(_ raw: Any?) -> String? {
    let value: String?
    if let raw = raw as? String {
        value = raw
    } else if let raw = raw as? [String: Any] {
        value = raw["url"] as? String
    } else {
        value = nil
    }
    guard var cleaned = value?.replacingOccurrences(of: "git+", with: "") else { return nil }
    if cleaned.hasSuffix(".git") {
        cleaned.removeLast(4)
    }
    return githubRepositoryURL(cleaned) ?? cleaned
}

private func githubRepositoryURL(_ string: String) -> String? {
    guard let url = URL(string: string),
          url.host()?.lowercased() == "github.com" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2 else { return nil }
    return "https://github.com/\(parts[0])/\(parts[1])"
}

private extension FileManager {
    func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private extension String {
    var latestVersionMarker: String? {
        guard let start = range(of: "[latest: ")?.upperBound,
              let end = self[start...].firstIndex(of: "]") else { return nil }
        return String(self[start..<end])
    }
}
