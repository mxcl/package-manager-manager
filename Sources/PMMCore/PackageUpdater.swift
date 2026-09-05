import Foundation

public struct PackageUpdater: Sendable {
    private let runner: CommandRunning
    private let homeDirectory: URL
    private let toolPaths: [String: String]
    private let environment: [String: String]

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolPaths: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.homeDirectory = homeDirectory
        self.toolPaths = toolPaths
        self.environment = environment
    }

    public func update(_ package: ManagedPackage, onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil) throws {
        guard package.isOutdated else { return }
        switch package.manager {
        case .cargoInstall:
            try run(
                firstOf: CargoToolchain(runner: runner, toolPaths: toolPaths)
                    .updateCommands(for: package.packageToken),
                onProgress: onProgress
            )
        case .apk, .apt, .dnf, .zypper, .macApp, .rustup, .mise, .skills:
            throw PackageUpdateError.unsupportedManager(package.manager)
        case .homebrew:
            try run("brew", ["upgrade", package.packageToken], onProgress: onProgress)
        case .npm:
            try run("npm", ["install", "-g", "\(package.packageToken)@latest"], onProgress: onProgress)
        case .pnpm:
            try run("pnpm", ["update", "-g", "--latest", package.packageToken], onProgress: onProgress)
        case .bun:
            try run("bun", ["update", "-g", "--latest", package.packageToken], onProgress: onProgress)
        case .npx:
            try run("npm", ["exec", "--yes", "--package", "\(package.packageToken)@\(package.latestVersion ?? "latest")", "--", "true"], onProgress: onProgress)
        case .uv:
            if package.summary == "uv-managed Python", let latestVersion = package.latestVersion {
                try run("uv", ["python", "install", latestVersion, "--color", "always"], onProgress: onProgress)
            } else {
                try run("uv", ["tool", "upgrade", package.packageToken, "--color", "always"], onProgress: onProgress)
            }
        case .pipx:
            try run("pipx", ["upgrade", package.packageToken], onProgress: onProgress)
        case .goInstall:
            try run("go", ["install", "\(package.packageToken)@latest"], onProgress: onProgress)
        case .pkgx:
            let targetSpecifier = package.latestVersion.map { "@\($0)" } ?? "@*"
            try run("pkgx", ["+\(package.packageToken)\(targetSpecifier)", "true"], onProgress: onProgress)
            if let latestVersion = package.latestVersion {
                let pkgxDir = environment["PKGX_DIR"] ?? ""
                let rootURL = pkgxDir.isEmpty ? homeDirectory.appendingPathComponent(".pkgx") : URL(fileURLWithPath: pkgxDir)
                let fallbackURL = homeDirectory.appendingPathComponent(".local/share/pkgx")
                let targetDir = rootURL.appendingPathComponent(package.packageToken).appendingPathComponent("v\(latestVersion)")
                let fallbackTargetDir = fallbackURL.appendingPathComponent(package.packageToken).appendingPathComponent("v\(latestVersion)")
                var isDir: ObjCBool = false
                let rootExists = FileManager.default.fileExists(atPath: rootURL.path) || FileManager.default.fileExists(atPath: fallbackURL.path)
                if rootExists {
                    let exists = (FileManager.default.fileExists(atPath: targetDir.path, isDirectory: &isDir) && isDir.boolValue)
                        || (FileManager.default.fileExists(atPath: fallbackTargetDir.path, isDirectory: &isDir) && isDir.boolValue)
                    if !exists {
                        throw PackageUpdateError.failed(
                            "pkgx +\(package.packageToken)\(targetSpecifier) true",
                            "Updated version \(latestVersion) was not found in pkgx directory after update."
                        )
                    }
                }
            }
        case .uvx:
            throw PackageUpdateError.unsupportedManager(package.manager)
        }
        PostHogTelemetry.shared.capturePackageUpdated(package)
    }

    public static func supports(_ package: ManagedPackage) -> Bool {
        switch package.manager {
        case .apk, .apt, .cargoInstall, .dnf, .zypper, .homebrew, .npm, .npx, .pnpm, .bun, .pipx, .uv, .goInstall, .pkgx: package.isOutdated
        case .macApp, .rustup, .mise, .skills, .uvx: false
        }
    }

    /// Runs commands in order until one succeeds, reporting each fallback as it happens. Managers
    /// whose preferred tool only covers some packages supply more than one command.
    private func run(
        firstOf commands: [PackageCommand],
        onProgress: (@Sendable (PackageCommandProgress) -> Void)?
    ) throws {
        guard let last = commands.last else { throw PackageUpdateError.missingExecutable("cargo") }
        for command in commands.dropLast() {
            do {
                return try run(command.executable, command.arguments, onProgress: onProgress)
            } catch {
                onProgress?(.output("\n\(command.displayName) failed; trying \(last.displayName).\n"))
            }
        }
        try run(last.executable, last.arguments, onProgress: onProgress)
    }

    private func run(
        _ executableName: String,
        _ arguments: [String],
        onProgress: (@Sendable (PackageCommandProgress) -> Void)?
    ) throws {
        guard let executable = toolPaths[executableName] ?? firstExecutable(named: executableName) else {
            throw PackageUpdateError.missingExecutable(executableName)
        }
        let command = ([executableName] + arguments).joined(separator: " ")
        onProgress?(.started(command: command))
        let result = try runner.run(executable, arguments, options: CommandRunOptions(terminal: true)) { output in
            onProgress?(.output(output))
        }
        guard result.status == 0 else {
            throw PackageUpdateError.failed(command, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}

/// A single command invocation, so a manager can express an ordered set of things to try.
public struct PackageCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Short label for progress messages, e.g. "cargo binstall".
    public var displayName: String {
        ([executable] + arguments.prefix(1)).joined(separator: " ")
    }

    public var displayCommand: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public enum PackageCommandProgress: Sendable, Equatable {
    case started(command: String)
    case output(String)
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
