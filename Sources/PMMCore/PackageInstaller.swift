import Foundation

public struct PackageInstaller: Sendable {
    private let runner: CommandRunning
    private let toolPaths: [String: String]

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        toolPaths: [String: String] = [:]
    ) {
        self.runner = runner
        self.toolPaths = toolPaths
    }

    public func install(_ package: ManagedPackage, onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil) throws {
        guard package.installedVersion == nil else { return }
        switch package.manager {
        case .homebrew:
            let arguments = package.identifier.hasPrefix("brew:cask:")
                ? ["install", "--cask", package.packageToken]
                : ["install", package.packageToken]
            try run("brew", arguments, onProgress: onProgress)
        case .npm:
            try run("npm", ["install", "-g", "\(package.packageToken)@latest"], onProgress: onProgress)
        case .cargoInstall:
            guard let helper = CargoHelper.allCases.first(where: { $0.crateName == package.packageToken }) else {
                throw PackageInstallError.unsupportedManager(package.manager)
            }
            try CargoToolchain(runner: runner, toolPaths: toolPaths).install(helper, onProgress: onProgress)
        case .macApp, .rustup, .mise, .npx, .skills, .uv, .uvx:
            throw PackageInstallError.unsupportedManager(package.manager)
        }
    }

    public static func supports(_ package: ManagedPackage) -> Bool {
        package.installedVersion == nil && (
            [.homebrew, .npm].contains(package.manager)
                || (package.manager == .cargoInstall && CargoHelper.allCases.contains { $0.crateName == package.packageToken })
        )
    }

    private func run(
        _ executableName: String,
        _ arguments: [String],
        onProgress: (@Sendable (PackageCommandProgress) -> Void)?
    ) throws {
        guard let executable = toolPaths[executableName] ?? firstExecutable(named: executableName) else {
            throw PackageInstallError.missingExecutable(executableName)
        }
        let command = ([executableName] + arguments).joined(separator: " ")
        onProgress?(.started(command: command))
        let result = try runner.run(executable, arguments, options: CommandRunOptions(terminal: true)) { output in
            onProgress?(.output(output))
        }
        guard result.status == 0 else {
            throw PackageInstallError.failed(command, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}

public enum PackageInstallError: LocalizedError, Equatable {
    case missingExecutable(String)
    case unsupportedManager(PackageManagerKind)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let executable):
            "Could not find \(executable)."
        case .unsupportedManager(let manager):
            "Installing \(manager.title) packages is not supported."
        case .failed(let command, let stderr):
            stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(command) failed."
                : "\(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
