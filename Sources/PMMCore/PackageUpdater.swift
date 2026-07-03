import Foundation

public struct PackageUpdater: Sendable {
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

    public func update(_ package: ManagedPackage) throws {
        guard package.isOutdated else { return }
        switch package.manager {
        case .cargoInstall:
            try run("cargo", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["install", package.packageToken, "--force", "--color", "never"])
        case .homebrew:
            try run("brew", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin"], ["upgrade", package.packageToken])
        case .npm:
            try run("npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["install", "-g", "\(package.packageToken)@latest"])
        case .npx:
            try run("npm", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["exec", "--yes", "--package", "\(package.packageToken)@\(package.latestVersion ?? "latest")", "--", "true"])
            if let path = package.installLocation {
                try removeNpxCacheEntry(at: path, root: homeDirectory.appendingPathComponent(".npm/_npx", isDirectory: true))
            }
        case .uv:
            if package.summary == "uv-managed Python", let latestVersion = package.latestVersion {
                try run("uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["python", "install", latestVersion, "--color", "never"])
            } else {
                try run("uv", extraPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], ["tool", "upgrade", package.packageToken, "--color", "never"])
            }
        case .uvx:
            throw PackageUpdateError.unsupportedManager(package.manager)
        }
    }

    public static func supports(_ package: ManagedPackage) -> Bool {
        switch package.manager {
        case .cargoInstall, .homebrew, .npm, .npx, .uv: package.isOutdated
        case .uvx: false
        }
    }

    private func run(_ executableName: String, extraPaths: [String], _ arguments: [String]) throws {
        guard let executable = toolPaths[executableName] ?? firstExecutable(named: executableName, extraPaths: extraPaths) else {
            throw PackageUpdateError.missingExecutable(executableName)
        }
        let result = try runner.run(executable, arguments)
        guard result.status == 0 else {
            throw PackageUpdateError.failed(([executableName] + arguments).joined(separator: " "), result.stderr)
        }
    }
}

public enum PackageUpdateError: LocalizedError, Equatable {
    case missingExecutable(String)
    case unsupportedManager(PackageManagerKind)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let executable):
            "Could not find \(executable)."
        case .unsupportedManager(let manager):
            "Updating \(manager.title) packages is not supported."
        case .failed(let command, let stderr):
            stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(command) failed."
                : "\(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
