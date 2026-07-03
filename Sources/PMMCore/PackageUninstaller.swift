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

    public func uninstall(_ package: ManagedPackage) throws {
        guard package.installedVersion != nil else { return }
        switch package.manager {
        case .cargoInstall:
            try run("cargo", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["uninstall", package.packageToken, "--color", "never"])
        case .homebrew:
            try run("brew", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin"], ["uninstall", package.packageToken])
        case .npm:
            try run("npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["uninstall", "-g", package.packageToken])
        case .npx:
            guard let path = package.installLocation else { throw PackageUninstallError.missingInstallLocation(package.displayName) }
            try removeNpxCacheEntry(at: path, root: homeDirectory.appendingPathComponent(".npm/_npx", isDirectory: true))
        case .uv:
            let arguments = package.summary == "uv-managed Python"
                ? ["python", "uninstall", package.installedVersion ?? package.packageToken, "--color", "never"]
                : ["tool", "uninstall", package.packageToken, "--color", "never"]
            try run("uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], arguments)
        case .uvx:
            try removeInstallLocation(package)
        }
    }

    private func run(_ executableName: String, extraPaths: [String], _ arguments: [String]) throws {
        guard let executable = toolPaths[executableName] ?? firstExecutable(named: executableName, extraPaths: extraPaths) else {
            throw PackageUninstallError.missingExecutable(executableName)
        }
        let result = try runner.run(executable, arguments)
        guard result.status == 0 else {
            throw PackageUninstallError.failed(([executableName] + arguments).joined(separator: " "), result.stderr)
        }
    }

    private func removeInstallLocation(_ package: ManagedPackage) throws {
        guard let path = package.installLocation else { throw PackageUninstallError.missingInstallLocation(package.displayName) }
        try FileManager.default.removeItem(atPath: path)
    }
}

func removeNpxCacheEntry(at path: String, root: URL, fileManager: FileManager = .default) throws {
    let rootPath = root.standardizedFileURL.path
    var url = URL(fileURLWithPath: path).standardizedFileURL
    while url.path != "/" {
        if url.deletingLastPathComponent().path == rootPath {
            try fileManager.removeItem(at: url)
            return
        }
        url.deleteLastPathComponent()
    }
    try fileManager.removeItem(atPath: path)
}

public enum PackageUninstallError: LocalizedError, Equatable {
    case missingExecutable(String)
    case missingInstallLocation(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let executable):
            "Could not find \(executable)."
        case .missingInstallLocation(let package):
            "No install location found for \(package)."
        case .failed(let command, let stderr):
            stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(command) failed."
                : "\(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
