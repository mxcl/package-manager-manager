import Foundation

public struct PackageScanner {
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    public func inventory(database: PackageDatabase) async -> PackageInventory {
        var errors: [String] = []
        var packages: [ManagedPackage] = []

        do { packages += try scanHomebrew(database: database) } catch { errors.append(error.localizedDescription) }
        do { packages += try scanNPM(database: database) } catch { errors.append(error.localizedDescription) }
        do { packages += try scanNPX(database: database) } catch { errors.append(error.localizedDescription) }

        return PackageInventory(
            packages: packages.sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            errors: errors
        )
    }

    public func scanHomebrew(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let brew = firstExecutable(named: "brew", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin"]) else { return [] }
        let outdated = try homebrewOutdated(brew)
        let formulae = try homebrewList(brew, kindFlag: "--formula", outdated: outdated.formulae, database: database)
        let casks = try homebrewList(brew, kindFlag: "--cask", outdated: outdated.casks, database: database)
        return formulae + casks
    }

    public func scanNPM(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let npm = firstExecutable(named: "npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
        let root = successfulLine(npm, ["root", "-g"])
        let prefix = successfulLine(npm, ["prefix", "-g"])
        let bin = prefix.map { "\($0)/bin" }
        let outdated = npmOutdated(npm)
        let result = try runner.run(npm, ["ls", "-g", "--depth=0", "--json"])
        guard let json = jsonObject(result.stdout),
              let dependencies = json["dependencies"] as? [String: Any] else { return [] }

        return dependencies.compactMap { name, raw in
            guard let body = raw as? [String: Any] else { return nil }
            let version = body["version"] as? String
            let metadata = database.metadata(for: .npm, name: name)
            return ManagedPackage(
                manager: .npm,
                name: name,
                installedVersion: version,
                latestVersion: outdated[name] ?? metadata?.version,
                summary: metadata?.summary,
                category: metadata?.category,
                homepage: metadata?.homepage,
                installLocation: root.map { "\($0)/\(name)" },
                binaryPath: npmBinaryPath(packageName: name, bin: bin)
            )
        }
    }

    public func scanNPX(database: PackageDatabase) throws -> [ManagedPackage] {
        let cache = homeDirectory.appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let cacheEntries = try? fileManager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else {
            return []
        }

        return cacheEntries.flatMap { entry -> [ManagedPackage] in
            let modules = entry.appendingPathComponent("node_modules", isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: modules.path) else { return [] }
            return names.flatMap { packageNames(in: modules, name: $0) }.compactMap { packageURL in
                guard let package = readPackageJSON(packageURL.appendingPathComponent("package.json")) else { return nil }
                let name = package.name
                let metadata = database.metadata(for: .npx, name: name)
                return ManagedPackage(
                    manager: .npx,
                    name: name,
                    installedVersion: package.version,
                    latestVersion: metadata?.version,
                    summary: metadata?.summary,
                    category: metadata?.category,
                    homepage: metadata?.homepage,
                    installLocation: packageURL.path,
                    binaryPath: nil
                )
            }
        }
    }

    private func homebrewList(
        _ brew: String,
        kindFlag: String,
        outdated: [String: String],
        database: PackageDatabase
    ) throws -> [ManagedPackage] {
        let result = try runner.run(brew, ["list", "--versions", kindFlag])
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let name = parts.first else { return nil }
            let version = parts.dropFirst().last
            let metadata = database.metadata(for: .homebrew, name: name)
            return ManagedPackage(
                manager: .homebrew,
                name: name,
                installedVersion: version,
                latestVersion: outdated[name] ?? metadata?.version,
                summary: metadata?.summary,
                category: metadata?.category,
                homepage: metadata?.homepage,
                installLocation: nil,
                binaryPath: nil
            )
        }
    }

    private func homebrewOutdated(_ brew: String) throws -> (formulae: [String: String], casks: [String: String]) {
        let result = try runner.run(brew, ["outdated", "--json=v2"])
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

    private func successfulLine(_ executable: String, _ arguments: [String]) -> String? {
        guard let result = try? runner.run(executable, arguments), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func npmBinaryPath(packageName: String, bin: String?) -> String? {
        guard let bin else { return nil }
        let path = "\(bin)/\(packageName)"
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    private func packageNames(in modules: URL, name: String) -> [URL] {
        let url = modules.appendingPathComponent(name, isDirectory: true)
        guard name.hasPrefix("@") else { return [url] }
        let scoped = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return scoped
    }

    private func readPackageJSON(_ url: URL) -> (name: String, version: String?)? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return (name, json["version"] as? String)
    }
}

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func outdatedMap(_ value: Any?) -> [String: String] {
    guard let array = value as? [[String: Any]] else { return [:] }
    return array.reduce(into: [:]) { result, item in
        guard let name = item["name"] as? String else { return }
        if let newest = item["current_version"] as? String, let installed = item["installed_versions"] as? [String], newest != installed.last {
            result[name] = newest
        } else if let newest = item["current_version"] as? String {
            result[name] = newest
        }
    }
}
