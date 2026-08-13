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
        PackageCommand(executable: "cargo", arguments: ["binstall", crate, "--no-confirm", "--force", "--locked"])
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

extension CargoHelper {
    /// This manager's key namespace, used for preferences, notifications, and offer identity alike.
    public var promptKey: String { "cargo.\(rawValue)" }

    public init?(promptKey: String) {
        guard let helper = CargoHelper.allCases.first(where: { $0.promptKey == promptKey }) else { return nil }
        self = helper
    }

    /// The copy shown when this helper is worth offering.
    public var setupOffer: ManagerSetupOffer {
        switch self {
        case .binstall:
            ManagerSetupOffer(
                id: promptKey,
                manager: .cargoInstall,
                title: "Install cargo-binstall?",
                explanation: "Downloads prebuilt binaries instead of compiling, so updates take seconds. Crates without one still compile.",
                symbolName: "bolt.fill"
            )
        case .installUpdate:
            ManagerSetupOffer(
                id: promptKey,
                manager: .cargoInstall,
                title: "Install cargo-update?",
                explanation: "Cargo can't tell which crates are outdated, so only catalogued ones show updates. cargo-update checks them all.",
                symbolName: "arrow.triangle.2.circlepath"
            )
        }
    }
}

/// Everything the Rust section needs to decide what, if anything, to offer.
///
/// Keeping this a value type means the decision is testable on its own and the view model holds one
/// property rather than a scattering of cargo-shaped fields.
public struct CargoSetupState: Sendable, Equatable {
    /// `nil` until detection has run, which is not the same as "nothing installed".
    public var status: CargoToolchainStatus?
    public var preferences: PackagePreferences

    /// The managers whose presence means Rust is actually in use here.
    static let rustManagers: Set<PackageManagerKind> = [.cargoInstall, .rustup]

    public init(
        status: CargoToolchainStatus? = nil,
        preferences: PackagePreferences = PackagePreferences()
    ) {
        self.status = status
        self.preferences = preferences
    }

    /// Detects what the toolchain has available. Shells out, so never call this on the main thread.
    public static func detect(preferences: PackagePreferences) -> CargoSetupState {
        CargoSetupState(status: CargoToolchain().status(), preferences: preferences)
    }

    /// Carries locally recorded dismissals forward across a detection.
    ///
    /// The two halves are named rather than taken from one `CargoSetupState`, because taking the
    /// wrong half is precisely the bug this guards against: detection reads preferences from disk
    /// on a background task, so a dismissal made while that read was in flight exists only in
    /// memory, and adopting the loaded set wholesale would bring the card the user just dismissed
    /// straight back. The status is the only half worth adopting; the preferences are folded.
    public func merging(status: CargoToolchainStatus?, preferences loaded: PackagePreferences) -> CargoSetupState {
        CargoSetupState(status: status, preferences: preferences.merging(loaded))
    }

    /// True while detection has not run for someone who does have Rust packages — the only case
    /// where an offer might still appear. "Not detected yet" is not "nothing to offer", and the
    /// card slot has to tell them apart to know whether to show a spinner.
    public func isAwaitingDetection(installedManagers: Set<PackageManagerKind>) -> Bool {
        status == nil && !installedManagers.isDisjoint(with: Self.rustManagers)
    }

    /// The one helper worth offering right now, or nil when there is nothing to ask.
    ///
    /// Offers are sequential and only ever made when Rust is actually in use: binstall first
    /// because it speeds up everything that follows, then cargo-update, which is the only way to
    /// learn that a crate outside the curated catalog is out of date.
    /// Cargo's helpers are only worth suggesting when Rust is actually in use here.
    public func offer(installedManagers: Set<PackageManagerKind>) -> CargoHelper? {
        offer(hasRustPackages: !installedManagers.isDisjoint(with: Self.rustManagers))
    }

    public func offer(hasRustPackages: Bool) -> CargoHelper? {
        guard let status, status.hasCargo, hasRustPackages else { return nil }
        return [CargoHelper.binstall, .installUpdate].first {
            !status.has($0) && !preferences.hasDismissed($0.promptKey)
        }
    }
}
