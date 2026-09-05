import Foundation

public struct PackageUninstaller: Sendable {
    private let runner: CommandRunning
    private let homeDirectory: URL
    private let toolPaths: [String: String]

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolPaths: [String: String] = [:]
    ) {
        self.runner = runner
        self.homeDirectory = homeDirectory
        self.toolPaths = toolPaths
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
        case .uvx:
            try removeInstallLocation(package)
        }
    }

    public static func supports(_ package: ManagedPackage) -> Bool {
        switch package.manager {
        case .apk, .apt, .cargoInstall, .dnf, .zypper, .homebrew, .npm, .npx, .pnpm, .bun, .pipx, .uv, .uvx, .goInstall:
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
        let result = try runner.run(executable, arguments, options: CommandRunOptions(terminal: true)) { output in
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
        let envBin = ProcessInfo.processInfo.environment["GOBIN"]
        if let envBin, !envBin.isEmpty { return envBin }
        if let go = toolPaths["go"] ?? firstExecutable(named: "go"),
           let result = try? runner.run(go, ["env", "GOBIN", "GOPATH"]), result.status == 0 {
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

    private func removeGoPackage(_ package: ManagedPackage) throws {
        guard let path = package.binaryPath ?? package.installLocation else {
            throw PackageUninstallError.missingInstallLocation(package.displayName)
        }
        let binDir = effectiveGoBinDirectory()
        let standardizedBinDir = URL(fileURLWithPath: binDir).standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let parentDir = URL(fileURLWithPath: standardizedPath).deletingLastPathComponent().path
        guard parentDir == standardizedBinDir else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Binary path \(path) is not inside Go bin directory \(binDir)")
        }
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            throw PackageUninstallError.failed("uninstall \(package.displayName)", "Binary does not exist at \(path)")
        }
        if let go = toolPaths["go"] ?? firstExecutable(named: "go") {
            let result = try runner.run(go, ["version", "-m", standardizedPath])
            guard result.status == 0, result.stdout.contains(package.packageToken) else {
                throw PackageUninstallError.failed("uninstall \(package.displayName)", "Binary does not match Go package \(package.packageToken)")
            }
        }
        try FileManager.default.removeItem(atPath: standardizedPath)
        for name in package.executableNames {
            let siblingPath = (binDir as NSString).appendingPathComponent(name)
            let standardizedSibling = URL(fileURLWithPath: siblingPath).standardizedFileURL.path
            if standardizedSibling != standardizedPath, FileManager.default.fileExists(atPath: standardizedSibling) {
                if let go = toolPaths["go"] ?? firstExecutable(named: "go") {
                    if let res = try? runner.run(go, ["version", "-m", standardizedSibling]),
                       res.status == 0, res.stdout.contains(package.packageToken) {
                        try? FileManager.default.removeItem(atPath: standardizedSibling)
                    }
                }
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
