import Foundation

public struct PackageScanner {
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let toolPaths: [String: String]

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolPaths: [String: String] = [:]
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.toolPaths = toolPaths
    }

    public func inventory(database: PackageDatabase) async -> PackageInventory {
        var errors: [String] = []
        var packages: [ManagedPackage] = []

        do { packages += try scanHomebrew(database: database) } catch { errors.append(error.localizedDescription) }
        do { packages += try scanNPM(database: database) } catch { errors.append(error.localizedDescription) }
        do { packages += try scanNPX(database: database) } catch { errors.append(error.localizedDescription) }
        do { packages += try scanUV(database: database) } catch { errors.append(error.localizedDescription) }
        do { packages += try scanUVX(database: database) } catch { errors.append(error.localizedDescription) }

        return PackageInventory(
            packages: packages.sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            errors: errors
        )
    }

    public func scanHomebrew(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let brew = executable(named: "brew", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin"]) else { return [] }
        let outdated = try homebrewOutdated(brew)
        let requestedFormulae = homebrewRequestedFormulae(brew)
        let formulae = try homebrewList(brew, kindFlag: "--formula", names: requestedFormulae, outdated: outdated.formulae, database: database)
        let casks = try homebrewList(brew, kindFlag: "--cask", outdated: outdated.casks, database: database)
        return formulae + casks
    }

    public func scanNPM(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let npm = executable(named: "npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
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
                lastUpdatedAt: metadata?.lastUpdatedAt,
                pulseKind: metadata?.pulseKind,
                installLocation: root.map { "\($0)/\(name)" },
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
                let metadata = database.metadata(for: .npx, name: name)
                return ManagedPackage(
                    manager: .npx,
                    name: name,
                    installedVersion: package.version,
                    latestVersion: metadata?.version,
                    summary: metadata?.summary,
                    category: metadata?.category,
                    homepage: metadata?.homepage,
                    lastUpdatedAt: metadata?.lastUpdatedAt,
                    pulseKind: metadata?.pulseKind,
                    installLocation: packageURL.path,
                    binaryPath: nil
                )
            }
        }
        return uniqued(packages)
    }

    public func scanUV(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let uv = executable(named: "uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else { return [] }
        let toolDir = successfulLine(uv, ["tool", "dir", "--offline", "--color", "never"])
        let pythonDir = successfulLine(uv, ["python", "dir", "--offline", "--color", "never"])
        return try uvTools(uv, toolDir: toolDir, database: database) + uvPythons(uv, pythonDir: pythonDir)
    }

    public func scanUVX(database: PackageDatabase) throws -> [ManagedPackage] {
        guard let uv = executable(named: "uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]),
              let cacheDir = successfulLine(uv, ["cache", "dir"]) else { return [] }
        let environments = URL(fileURLWithPath: cacheDir).appendingPathComponent("environments-v2", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: environments, includingPropertiesForKeys: nil) else { return [] }

        return entries.compactMap { entry in
            let envName = entry.lastPathComponent
            guard !envName.hasPrefix(".") else { return nil }
            let name = uvxDisplayName(envName)
            let dist = matchingDistInfo(in: entry, packageName: name)
            return ManagedPackage(
                manager: .uvx,
                name: name,
                installedVersion: dist?.version,
                latestVersion: nil,
                summary: "uvx cached tool environment",
                category: "developer-tools",
                installLocation: entry.path,
                binaryPath: uvxBinaryPath(in: entry, preferredName: name)
            )
        }
    }

    private func homebrewList(
        _ brew: String,
        kindFlag: String,
        names: Set<String>? = nil,
        outdated: [String: String],
        database: PackageDatabase
    ) throws -> [ManagedPackage] {
        let result = try runner.run(brew, ["list", "--versions", kindFlag])
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let name = parts.first else { return nil }
            if let names, !names.contains(name) { return nil }
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
                lastUpdatedAt: metadata?.lastUpdatedAt,
                pulseKind: metadata?.pulseKind,
                installLocation: nil,
                binaryPath: nil
            )
        }
    }

    private func homebrewRequestedFormulae(_ brew: String) -> Set<String>? {
        if let lines = successfulLines(brew, ["leaves", "--installed-on-request"]) {
            return Set(lines)
        }
        return successfulLines(brew, ["leaves"]).map(Set.init)
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

    private func uvTools(_ uv: String, toolDir: String?, database: PackageDatabase) throws -> [ManagedPackage] {
        let result = try runner.run(uv, ["tool", "list", "--show-paths", "--show-version-specifiers", "--show-python", "--offline", "--color", "never"])
        guard result.status == 0 else { return [] }
        return parseUVToolList(result.stdout, toolDir: toolDir, outdated: uvToolOutdated(uv), database: database)
    }

    private func uvPythons(_ uv: String, pythonDir: String?) throws -> [ManagedPackage] {
        guard let pythonDir else { return [] }
        let latest = uvPythonLatestVersions(uv)
        let result = try runner.run(uv, ["python", "list", "--only-installed", "--output-format", "json", "--offline", "--color", "never"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"] as? String,
                  path == pythonDir || path.hasPrefix("\(pythonDir)/"),
                  let key = row["key"] as? String,
                  let version = row["version"] as? String else { return nil }
            let latestVersion = uvPythonKey(row).flatMap { latest[$0] }.flatMap { $0 == version ? nil : $0 }
            return ManagedPackage(
                manager: .uv,
                name: key,
                installedVersion: version,
                latestVersion: latestVersion,
                summary: "uv-managed Python",
                category: "language-runtime",
                installLocation: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                binaryPath: path
            )
        }
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
                name: tool.name,
                installedVersion: tool.version,
                latestVersion: tool.latest ?? outdated[tool.name] ?? metadata?.version,
                summary: metadata?.summary ?? "uv-installed tool",
                category: metadata?.category ?? "developer-tools",
                homepage: metadata?.homepage,
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

    private func successfulLine(_ executable: String, _ arguments: [String]) -> String? {
        guard let result = try? runner.run(executable, arguments), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func successfulLines(_ executable: String, _ arguments: [String]) -> [String]? {
        guard let result = try? runner.run(executable, arguments), result.status == 0 else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func executable(named name: String, extraPaths: [String]) -> String? {
        toolPaths[name] ?? firstExecutable(named: name, extraPaths: extraPaths)
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

    private func readPackageJSON(_ url: URL) -> (name: String, version: String?)? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return (name, json["version"] as? String)
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

    private func matchingDistInfo(in environment: URL, packageName: String) -> (name: String, version: String?)? {
        let lib = environment.appendingPathComponent("lib", isDirectory: true)
        guard let pythonDirs = try? fileManager.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil) else { return nil }
        let normalizedPackage = normalizedPythonPackageName(packageName)
        for pythonDir in pythonDirs {
            let sitePackages = pythonDir.appendingPathComponent("site-packages", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(at: sitePackages, includingPropertiesForKeys: nil) else { continue }
            if let entry = entries.first(where: { entry in
                guard entry.pathExtension == "dist-info",
                      let distName = distInfoNameAndVersion(entry.deletingPathExtension().lastPathComponent)?.name else { return false }
                return normalizedPythonPackageName(distName) == normalizedPackage
            }) {
                let stem = entry.deletingPathExtension().lastPathComponent
                return distInfoNameAndVersion(stem)
            }
        }
        return nil
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

    private func uniqued(_ packages: [ManagedPackage]) -> [ManagedPackage] {
        var seen = Set<String>()
        return packages.filter {
            seen.insert("\($0.manager.rawValue):\($0.name):\($0.installedVersion ?? "")").inserted
        }
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
