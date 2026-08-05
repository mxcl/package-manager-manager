import Foundation

/// The optional cargo helper subcommands PMM knows how to take advantage of.
public enum CargoHelper: String, Sendable, CaseIterable {
    /// Provides `cargo binstall`.
    case binstall
    /// Provides `cargo install-update`, which is the only programmatic way to learn what a
    /// `cargo install`-ed crate's latest version is without querying a registry directly.
    case installUpdate

    /// The crate to install.
    public var crateName: String {
        switch self {
        case .binstall: "cargo-binstall"
        case .installUpdate: "cargo-update"
        }
    }

    /// The executable the crate drops in `~/.cargo/bin`, which is not the same as the crate name
    /// for cargo-update.
    public var executableName: String {
        switch self {
        case .binstall: "cargo-binstall"
        case .installUpdate: "cargo-install-update"
        }
    }
}

public struct CargoToolchainStatus: Sendable, Equatable {
    public let cargo: String?
    public let binstall: String?
    public let installUpdate: String?

    public init(cargo: String?, binstall: String?, installUpdate: String?) {
        self.cargo = cargo
        self.binstall = binstall
        self.installUpdate = installUpdate
    }

    public var hasCargo: Bool { cargo != nil }
    public var hasBinstall: Bool { binstall != nil }
    public var hasInstallUpdate: Bool { installUpdate != nil }

    public func has(_ helper: CargoHelper) -> Bool {
        switch helper {
        case .binstall: hasBinstall
        case .installUpdate: hasInstallUpdate
        }
    }
}

public enum CargoToolchainError: Error, LocalizedError, Equatable {
    case cargoUnavailable
    case helperUnavailable(CargoHelper)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cargoUnavailable:
            "cargo could not be found."
        case .helperUnavailable(let helper):
            "\(helper.crateName) is not installed."
        case .commandFailed(let output):
            output
        }
    }
}

public struct CargoToolchain: Sendable {
    private let runner: CommandRunning
    private let toolPaths: [String: String]
    private let environment: [String: String]?
    private let home: URL
    /// Injectable because `toolPaths` can force a tool present but cannot say one is absent — and
    /// without that, a test for the not-on-PATH case silently passes on any machine that happens to
    /// have the helper installed, which is every developer machine that has ever used one.
    private let findOnPath: @Sendable (String) -> String?

    public init(
        runner: CommandRunning = SystemCommandRunner(),
        toolPaths: [String: String] = [:],
        environment: [String: String]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        findOnPath: @escaping @Sendable (String) -> String? = { firstExecutable(named: $0) }
    ) {
        self.runner = runner
        self.toolPaths = toolPaths
        self.findOnPath = findOnPath
        self.environment = environment
        self.home = home
    }

    public func status() -> CargoToolchainStatus {
        CargoToolchainStatus(
            cargo: executable(named: "cargo"),
            binstall: executable(named: CargoHelper.binstall.executableName),
            installUpdate: executable(named: CargoHelper.installUpdate.executableName)
        )
    }

    /// Installs a helper crate. Uses binstall when it is already available, since bootstrapping
    /// cargo-update by compiling it is exactly the wait this feature exists to avoid.
    public func install(
        _ helper: CargoHelper,
        status: CargoToolchainStatus? = nil,
        onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil
    ) throws {
        let resolved = status ?? self.status()
        guard let cargo = resolved.cargo else { throw CargoToolchainError.cargoUnavailable }

        var failure: CargoToolchainError?
        for command in installCommands(for: helper, status: resolved) {
            onProgress?(.started(command: command.displayCommand))
            let result = try runner.run(cargo, command.arguments, options: CommandRunOptions(terminal: true)) { output in
                onProgress?(.output(output))
            }
            if result.status == 0 { return }
            failure = .commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            onProgress?(.output("\n\(command.displayCommand) failed.\n"))
        }
        throw failure ?? .cargoUnavailable
    }

    /// The commands to try, in order, to bring a crate up to date.
    ///
    /// binstall goes first whenever it is installed, because it downloads a prebuilt binary instead
    /// of compiling. It is not universal — a crate whose maintainer publishes no release artifacts
    /// will fail — so `cargo install` always remains as the trailing fallback.
    public func updateCommands(for crate: String, status: CargoToolchainStatus? = nil) -> [PackageCommand] {
        let compile = Self.compileCommand(crate)
        guard (status ?? self.status()).hasBinstall else { return [compile] }
        return [Self.binstallCommand(crate), compile]
    }

    /// The commands to try, in order, to install a helper crate.
    ///
    /// binstall bootstraps everything except itself, since compiling it is exactly the wait it
    /// exists to avoid. Compiling stays as the fallback so a helper without prebuilt artifacts, or
    /// a binstall that fails outright, still installs.
    func installCommands(for helper: CargoHelper, status: CargoToolchainStatus) -> [PackageCommand] {
        let compile = Self.compileCommand(helper.crateName)
        guard status.hasBinstall, helper != .binstall else { return [compile] }
        return [Self.binstallCommand(helper.crateName), compile]
    }

    private static func compileCommand(_ crate: String) -> PackageCommand {
        PackageCommand(executable: "cargo", arguments: ["install", crate, "--force", "--color", "always"])
    }

    // --force matters: without it binstall exits 0 without doing anything whenever cargo's install
    // metadata already records the target version, even if the binary itself is long gone.
    private static func binstallCommand(_ crate: String) -> PackageCommand {
        PackageCommand(executable: "cargo", arguments: ["binstall", crate, "--no-confirm", "--force"])
    }

    /// Latest versions keyed by crate name, via `cargo install-update --list`. This only reports
    /// crates cargo-update can resolve — git and path installs are simply absent.
    public func latestVersions(status: CargoToolchainStatus? = nil) throws -> [String: String] {
        let resolved = status ?? self.status()
        guard let cargo = resolved.cargo else { throw CargoToolchainError.cargoUnavailable }
        guard resolved.hasInstallUpdate else {
            throw CargoToolchainError.helperUnavailable(.installUpdate)
        }
        // The one command on the scan path that talks to a registry, and the one that stalls.
        let result = try runner.run(
            cargo,
            ["install-update", "--list"],
            options: CommandRunOptions(inactivityTimeout: defaultQueryInactivityTimeout)
        )
        guard result.status == 0 else {
            throw CargoToolchainError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return Self.parseInstallUpdateList(result.stdout)
    }

    /// Parses the table `cargo install-update --list` prints:
    ///
    ///     Package         Installed  Latest   Needs update
    ///     cargo-binstall  v1.21.0    v1.21.1  Yes
    ///     just            v1.5.0     v1.57.0  Yes
    static func parseInstallUpdateList(_ output: String) -> [String: String] {
        var latest: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 4,
                  columns[0] != "Package",
                  columns[1].hasPrefix("v"),
                  columns[2].hasPrefix("v")
            else { continue }
            latest[columns[0]] = String(columns[2].dropFirst())
        }
        return latest
    }

    private func executable(named name: String) -> String? {
        if let path = toolPaths[name] { return path }
        if let path = findOnPath(name) { return path }
        // Where cargo actually installs things, whether or not it is on this process's PATH — and
        // for a Finder-launched app whose cargo came from Homebrew, it is not. A helper installed
        // there reported success, stayed undetected, and the card asking to install it came back.
        // Cargo finds its own subcommands here regardless of PATH, so only the detection was wrong.
        let candidate = cargoInstallRoot.appendingPathComponent("bin").appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private var cargoInstallRoot: URL {
        let environment = environment ?? commandEnvironment()
        if let root = environment["CARGO_INSTALL_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        if let root = environment["CARGO_HOME"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return home.appendingPathComponent(".cargo", isDirectory: true)
    }
}
