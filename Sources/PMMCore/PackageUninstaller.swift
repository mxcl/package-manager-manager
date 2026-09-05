import Foundation

public struct PackageUninstaller: Sendable {
    private let runner: CommandRunning
    private let homeDirectory: URL
    private let toolPaths: [String: String]
    private let environment: [String: String]?
    private let fileManager: FileManager

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolPaths: [String: String] = [:],
        environment: [String: String]? = nil,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.homeDirectory = homeDirectory
        self.toolPaths = toolPaths
        self.environment = environment
        self.fileManager = fileManager
    }

    private var effectiveEnvironment: [String: String] {
        environment ?? commandEnvironment()
    }

    public func uninstall(_ package: ManagedPackage, onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil) throws {
        guard package.installedVersion != nil else { return }
        switch package.manager {
        case .cargoInstall:
            try run("cargo", ["uninstall", package.packageToken, "--color", "always"], onProgress: onProgress)
        case .apk, .apt, .dnf, .zypper, .macApp, .rustup, .mise:
            throw PackageUninstallError.unsupportedManager(package.manager)
        case .homebrew:
            try run("brew", ["uninstall", package.packageToken], onProgress: onProgress)
        case .npm:
            try run("npm", ["uninstall", "-g", package.packageToken], onProgress: onProgress)
        case .pnpm:
            try run("pnpm", ["remove", "-g", package.packageToken], onProgress: onProgress)
        case .bun:
            try run("bun", ["remove", "-g", package.packageToken], onProgress: onProgress)
        case .npx:
            try removeCachedPackage(package, root: homeDirectory.appendingPathComponent(".npm/_npx", isDirectory: true))
        case .skills:
            guard package.identifier.hasPrefix("skills:global:") else {
                throw PackageUninstallError.unsupportedManager(package.manager)
            }
            try removeSkill(package, onProgress: onProgress)
        case .uv:
            let arguments = package.summary == "uv-managed Python"
                ? ["python", "uninstall", package.installedVersion ?? package.packageToken, "--color", "always"]
                : ["tool", "uninstall", package.packageToken, "--color", "always"]
            try run("uv", arguments, onProgress: onProgress)
        case .pipx:
            try run("pipx", ["uninstall", package.packageToken], onProgress: onProgress)
        case .goInstall:
            try removeGoPackage(package)
        case .pkgx:
            try removePkgxPackage(package)
        case .uvx:
            try removeInstallLocation(package)
        }
    }

    public static func supports(_ package: ManagedPackage) -> Bool {
        switch package.manager {
        case .apk, .apt, .cargoInstall, .dnf, .zypper, .homebrew, .npm, .npx, .pnpm, .bun, .pipx, .uv, .uvx, .goInstall, .pkgx:
            package.installedVersion != nil
        case .skills:
            package.installedVersion != nil && package.identifier.hasPrefix("skills:global:")
        case .macApp, .rustup, .mise:
            false
        }
    }

    private func run(
        _ executableName: String,
        _ arguments: [String],
        onProgress: (@Sendable (PackageCommandProgress) -> Void)?
    ) throws {
        guard let executable = toolPaths[executableName] ?? firstExecutable(named: executableName) else {
            throw PackageUninstallError.missingExecutable(executableName)
        }
        let command = ([executableName] + arguments).joined(separator: " ")
        onProgress?(.started(command: command))
        let options = CommandRunOptions(terminal: true, environment: effectiveEnvironment)
        let result = try runner.run(executable, arguments, options: options) { output in
            onProgress?(.output(output))
        }
        guard result.status == 0 else {
            throw PackageUninstallError.failed(command, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func removeCachedPackage(_ package: ManagedPackage, root: URL) throws {
        guard let path = package.installLocation else { throw PackageUninstallError.missingInstallLocation(package.displayName) }
        let rootPath = root.standardizedFileURL.path
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/" {
            if url.deletingLastPathComponent().path == rootPath {
                try FileManager.default.removeItem(at: url)
                return
            }
            url.deleteLastPathComponent()
        }
        try FileManager.default.removeItem(atPath: path)
    }

    private func removeSkill(
        _ package: ManagedPackage,
        onProgress: (@Sendable (PackageCommandProgress) -> Void)?
    ) throws {
        let arguments = ["remove", package.packageToken, "--global", "--yes"]
        if toolPaths["skills"] != nil {
            try run("skills", arguments, onProgress: onProgress)
        } else if toolPaths["npx"] != nil {
            try run("npx", ["--yes", "skills"] + arguments, onProgress: onProgress)
        } else if firstExecutable(named: "skills") != nil {
            try run("skills", arguments, onProgress: onProgress)
        } else {
            try run("npx", ["--yes", "skills"] + arguments, onProgress: onProgress)
        }
    }

    private func removeInstallLocation(_ package: ManagedPackage) throws {
        guard let path = package.installLocation else { throw PackageUninstallError.missingInstallLocation(package.displayName) }
        try FileManager.default.removeItem(atPath: path)
    }

    private func effectiveGoBinDirectory() -> String {
        let env = effectiveEnvironment
        let envBin = env["GOBIN"]
        if let envBin, !envBin.isEmpty { return envBin }
        if let envGopath = env["GOPATH"], !envGopath.isEmpty {
            let firstPath = envGopath.split(separator: ":").first.map(String.init) ?? envGopath
            return (firstPath as NSString).appendingPathComponent("bin")
        }
        if let go = toolPaths["go"] ?? firstExecutable(named: "go"), !go.isEmpty,
           let result = try? runner.run(go, ["env", "GOBIN", "GOPATH"], options: CommandRunOptions(environment: env)), result.status == 0 {
            let lines = result.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if lines.count >= 1, !lines[0].isEmpty {
                return lines[0]
            }
            if lines.count >= 2, !lines[1].isEmpty {
                let firstPath = lines[1].split(separator: ":").first.map(String.init) ?? lines[1]
                return (firstPath as NSString).appendingPathComponent("bin")
            }
        }
        return homeDirectory.appendingPathComponent("go/bin").path
    }

    static func parseGoPackagePath(from output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("path\t") || trimmed.hasPrefix("path ") {
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, parts[0] == "path" {
                    return String(parts[1])
                }
            }
        }
        return nil
    }

    private func removeGoPackage(_ package: ManagedPackage) throws {
        guard let path = package.binaryPath ?? package.installLocation else {
            throw PackageUninstallError.missingInstallLocation(package.displayName)
        }
        guard let go = toolPaths["go"] ?? firstExecutable(named: "go"), !go.isEmpty else {
            throw PackageUninstallError.missingExecutable("go")
        }
        let binDir = effectiveGoBinDirectory()
        let standardizedBinDir = URL(fileURLWithPath: binDir).standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let parentDir = URL(fileURLWithPath: standardizedPath).deletingLastPathComponent().path
        guard parentDir == standardizedBinDir else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Binary path \(path) is not inside Go bin directory \(binDir)")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedPath, isDirectory: &isDir), !isDir.boolValue else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Binary does not exist or is a directory at \(path)")
        }

        let expectedPath = package.identifier.hasPrefix("go:") ? String(package.identifier.dropFirst(3)) : package.packageToken
        let options = CommandRunOptions(environment: effectiveEnvironment)
        let result = try runner.run(go, ["version", "-m", standardizedPath], options: options)
        guard result.status == 0,
              let actualPath = Self.parseGoPackagePath(from: result.stdout),
              actualPath == expectedPath else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Binary does not match Go package \(expectedPath)")
        }

        try FileManager.default.removeItem(atPath: standardizedPath)

        for name in package.executableNames {
            let siblingPath = (binDir as NSString).appendingPathComponent(name)
            let standardizedSibling = URL(fileURLWithPath: siblingPath).standardizedFileURL.path
            if standardizedSibling != standardizedPath {
                var isSiblingDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: standardizedSibling, isDirectory: &isSiblingDir), !isSiblingDir.boolValue {
                    if let res = try? runner.run(go, ["version", "-m", standardizedSibling], options: options),
                       res.status == 0,
                       Self.parseGoPackagePath(from: res.stdout) == expectedPath {
                        try? FileManager.default.removeItem(atPath: standardizedSibling)
                    }
                }
            }
        }
    }

    private func effectivePkgxDirectory() -> String {
        PackageScanner.effectivePkgxDirectory(
            environment: effectiveEnvironment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    private func removePkgxPackage(_ package: ManagedPackage) throws {
        guard let location = package.installLocation else {
            throw PackageUninstallError.missingInstallLocation(package.displayName)
        }
        let pkgxDir = effectivePkgxDirectory()
        let rootURL = URL(fileURLWithPath: pkgxDir)
        let locationURL = URL(fileURLWithPath: location)

        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let realLocation = locationURL.resolvingSymlinksInPath().standardizedFileURL.path

        guard realLocation.hasPrefix(realRoot + "/") else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Install location \(location) is not inside pkgx directory \(pkgxDir)")
        }

        var checkURL = locationURL
        while checkURL.path != rootURL.path && checkURL.path != "/" && checkURL.path != "." {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: checkURL.path)) != nil {
                throw PackageUninstallError.failed("uninstall \(package.displayName)", "Install location contains symbolic link at \(checkURL.path)")
            }
            checkURL = checkURL.deletingLastPathComponent()
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: realLocation, isDirectory: &isDir), isDir.boolValue else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Install location does not exist or is not a directory at \(location)")
        }

        let expectedProject = package.identifier.hasPrefix("pkgx:") ? String(package.identifier.dropFirst(5)) : package.packageToken
        let relative = String(realLocation.dropFirst(realRoot.count + 1))
        guard relative.hasPrefix(expectedProject + "/v") || relative == expectedProject else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Target path \(location) does not match pkgx package \(expectedProject)")
        }

        try FileManager.default.removeItem(atPath: realLocation)

        var projectDir = URL(fileURLWithPath: realLocation).deletingLastPathComponent().path
        while projectDir.hasPrefix(realRoot + "/") && projectDir != realRoot {
            if let remaining = try? FileManager.default.contentsOfDirectory(atPath: projectDir) {
                let liveDirectories = remaining.filter { entry in
                    let entryPath = (projectDir as NSString).appendingPathComponent(entry)
                    var subIsDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: entryPath, isDirectory: &subIsDir) && subIsDir.boolValue
                }
                if liveDirectories.isEmpty {
                    try? FileManager.default.removeItem(atPath: projectDir)
                    projectDir = URL(fileURLWithPath: projectDir).deletingLastPathComponent().path
                } else {
                    break
                }
            } else {
                break
            }
        }
    }
}

public enum PackageUninstallError: LocalizedError, Equatable {
    case missingExecutable(String)
    case unsupportedManager(PackageManagerKind)
    case missingInstallLocation(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let executable):
            "Could not find \(executable)."
        case .unsupportedManager(let manager):
            "Uninstalling \(manager.title) packages is not supported."
        case .missingInstallLocation(let package):
            "No install location found for \(package)."
        case .failed(let command, let stderr):
            stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(command) failed."
                : "\(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
