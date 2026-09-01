import Foundation
import Testing
@testable import PMMCore

@Test func cargoHelperCrateAndExecutableNamesDiffer() {
    // cargo-update installs an executable called cargo-install-update; conflating the two would
    // make detection always fail.
    #expect(CargoHelper.installUpdate.crateName == "cargo-update")
    #expect(CargoHelper.installUpdate.executableName == "cargo-install-update")
    #expect(CargoHelper.binstall.crateName == "cargo-binstall")
    #expect(CargoHelper.binstall.executableName == "cargo-binstall")
}

@Test func parseInstallUpdateListReadsLatestVersions() {
    let output = """
    Package         Installed  Latest   Needs update
    cargo-binstall  v1.21.0    v1.21.1  Yes
    just            v1.5.0     v1.57.0  Yes
    cbindgen        v0.29.4    v0.29.4  No
    """

    #expect(CargoToolchain.parseInstallUpdateList(output) == [
        "cargo-binstall": "1.21.1",
        "just": "1.57.0",
        "cbindgen": "0.29.4",
    ])
}

@Test func parseInstallUpdateListSkipsHeaderAndNoise() {
    let output = """
    Polling registry 'crates.io'...

    Package  Installed  Latest  Needs update
    mdtask   v0.3.0     v0.6.0  Yes

    Updating registry
    """

    #expect(CargoToolchain.parseInstallUpdateList(output) == ["mdtask": "0.6.0"])
}

@Test func parseInstallUpdateListIgnoresRowsWithoutVersionColumns() {
    #expect(CargoToolchain.parseInstallUpdateList("nothing here at all").isEmpty)
    #expect(CargoToolchain.parseInstallUpdateList("").isEmpty)
}

@Test func updateCommandsTryBinstallThenFallBackToCompiling() {
    let toolchain = CargoToolchain(runner: StubRunner())
    let status = CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: nil)

    // Not every crate publishes prebuilt artifacts, so compiling must remain as the trailing
    // fallback rather than the update dead-ending on a binstall miss.
    #expect(toolchain.updateCommands(for: "just", status: status) == [
        PackageCommand(executable: "cargo", arguments: ["binstall", "just", "--no-confirm", "--force", "--locked"]),
        PackageCommand(executable: "cargo", arguments: ["install", "just", "--force", "--color", "always"]),
    ])
}

@Test func updateCommandsCompileOnlyWhenBinstallIsMissing() {
    let toolchain = CargoToolchain(runner: StubRunner())
    let status = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)

    #expect(toolchain.updateCommands(for: "just", status: status) == [
        PackageCommand(executable: "cargo", arguments: ["install", "just", "--force", "--color", "always"]),
    ])
}

@Test func packagePreferencesRecordDismissalsUnderEachManagersOwnKeys() {
    var preferences = PackagePreferences()
    #expect(!preferences.hasDismissed(CargoHelper.binstall.promptKey))

    preferences.dismiss(CargoHelper.binstall.promptKey)
    #expect(preferences.hasDismissed(CargoHelper.binstall.promptKey))
    // Namespacing keeps one manager's dismissals from affecting another's.
    #expect(!preferences.hasDismissed(CargoHelper.installUpdate.promptKey))
    #expect(!preferences.hasDismissed("homebrew.something"))
}

@Test func preferencesStoreKeepsBothDismissalsWhenSavesLandOutOfOrder() throws {
    // Two dismissals in a row used to schedule two independent writes. If the older `{binstall}`
    // landed last it replaced `{binstall, cargo-update}` on disk, and the second prompt came back
    // after relaunch. Saving newest-first here is the worst case for a plain overwrite.
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-prefs-order-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = PackagePreferencesStore(url: url)

    var first = PackagePreferences()
    first.dismiss(CargoHelper.binstall.promptKey)
    var second = first
    second.dismiss(CargoHelper.installUpdate.promptKey)

    store.save(second)
    store.save(first)
    store.flush()

    let loaded = store.load()
    #expect(loaded.hasDismissed(CargoHelper.binstall.promptKey))
    #expect(loaded.hasDismissed(CargoHelper.installUpdate.promptKey))
}

@Test func packagePreferencesRoundTripThroughTheStore() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-prefs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = PackagePreferencesStore(url: url)

    #expect(store.load() == PackagePreferences())
    var preferences = PackagePreferences()
    preferences.dismiss(CargoHelper.installUpdate.promptKey)
    store.save(preferences)
    // `save` hands the write to the store's queue and returns, so reading needs the barrier.
    store.flush()

    #expect(store.load().hasDismissed(CargoHelper.installUpdate.promptKey))
}

@Test func latestVersionsRequiresCargoUpdate() {
    let toolchain = CargoToolchain(runner: StubRunner(), toolPaths: ["cargo": "/usr/bin/false"])
    // Status is passed explicitly so the assertion does not depend on whether cargo-update
    // happens to be installed on the machine running the suite.
    let absent = CargoToolchainStatus(cargo: "/usr/bin/false", binstall: nil, installUpdate: nil)
    #expect(throws: CargoToolchainError.helperUnavailable(.installUpdate)) {
        try toolchain.latestVersions(status: absent)
    }
}

@Test func statusReportsHelpersFromToolPaths() {
    let toolchain = CargoToolchain(
        runner: StubRunner(),
        toolPaths: [
            "cargo": "/c",
            "cargo-binstall": "/b",
            "cargo-install-update": "/u",
        ]
    )
    let status = toolchain.status()

    #expect(status.hasCargo)
    #expect(status.has(.binstall))
    #expect(status.has(.installUpdate))
}

@Test func cargoSetupOffersBinstallFirstThenCargoUpdate() {
    let none = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil))
    #expect(none.offer(hasRustPackages: true) == .binstall)

    let withBinstall = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: nil))
    #expect(withBinstall.offer(hasRustPackages: true) == .installUpdate)

    let complete = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: "/u"))
    #expect(complete.offer(hasRustPackages: true) == nil)
}

@Test func cargoSetupSkipsDeclinedHelpersAndMovesOn() {
    var preferences = PackagePreferences()
    preferences.dismiss(CargoHelper.binstall.promptKey)
    let status = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)

    // Declining binstall must not block the cargo-update offer.
    #expect(CargoSetupState(status: status, preferences: preferences).offer(hasRustPackages: true) == .installUpdate)

    preferences.dismiss(CargoHelper.installUpdate.promptKey)
    #expect(CargoSetupState(status: status, preferences: preferences).offer(hasRustPackages: true) == nil)
}

@Test func cargoSetupStaysSilentWithoutRustOrBeforeDetection() {
    let status = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)
    #expect(CargoSetupState(status: status).offer(hasRustPackages: false) == nil)

    let noCargo = CargoToolchainStatus(cargo: nil, binstall: nil, installUpdate: nil)
    #expect(CargoSetupState(status: noCargo).offer(hasRustPackages: true) == nil)

    // Undetected must not be mistaken for "nothing installed" and prompt on launch.
    #expect(CargoSetupState().offer(hasRustPackages: true) == nil)
}

@Test func installBinstallAlwaysCompilesBecauseItCannotBootstrapItself() throws {
    let runner = StubRunner()
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    try toolchain.install(.binstall, status: present)

    #expect(runner.commands == ["/fake/cargo install cargo-binstall --force --color always"])
}

@Test func installCargoUpdateUsesBinstallWhenAvailable() throws {
    let runner = StubRunner()
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    // Compiling cargo-update is the multi-minute wait binstall exists to avoid.
    try toolchain.install(.installUpdate, status: present)

    #expect(runner.commands == ["/fake/cargo binstall cargo-update --no-confirm --force --locked"])
}

@Test func binstallAlwaysForces() {
    // Without --force, binstall exits 0 having done nothing whenever cargo's install metadata
    // already records the target version, even if the binary is gone. That reads as success and
    // leaves the tool missing.
    let toolchain = CargoToolchain(runner: StubRunner(), toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    #expect(toolchain.updateCommands(for: "just", status: present).first?.arguments.contains("--force") == true)
    #expect(toolchain.installCommands(for: .installUpdate, status: present).first?.arguments.contains("--force") == true)
}

@Test func installFallsBackToCompilingWhenBinstallFails() throws {
    let runner = StubRunner()
    runner.failingCommandSubstring = "binstall"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    try toolchain.install(.installUpdate, status: present)

    #expect(runner.commands == [
        "/fake/cargo binstall cargo-update --no-confirm --force --locked",
        "/fake/cargo install cargo-update --force --color always",
    ])
}

@Test func installThrowsWhenEveryCommandFails() {
    let runner = StubRunner()
    runner.status = 1
    runner.stderr = "nope\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let present = CargoToolchainStatus(cargo: "/fake/cargo", binstall: "/b", installUpdate: nil)

    #expect(throws: CargoToolchainError.commandFailed("nope\n")) {
        try toolchain.install(.installUpdate, status: present)
    }
    #expect(runner.commands.count == 2)
}

@Test func installCargoUpdateCompilesWithoutBinstall() throws {
    let runner = StubRunner()
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let absent = CargoToolchainStatus(cargo: "/fake/cargo", binstall: nil, installUpdate: nil)

    try toolchain.install(.installUpdate, status: absent)

    #expect(runner.commands == ["/fake/cargo install cargo-update --force --color always"])
}

@Test func installReportsCommandAndStreamsOutput() throws {
    // Regression: without these events the UI has no running action to render, so a multi-minute
    // compile shows no terminal and looks hung.
    let runner = StubRunner()
    runner.streamedOutput = "Compiling hickory-proto\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let absent = CargoToolchainStatus(cargo: "/fake/cargo", binstall: nil, installUpdate: nil)
    let progress = ProgressRecorder()

    try toolchain.install(.binstall, status: absent) { progress.append($0) }

    #expect(progress.values == [
        .started(command: "cargo install cargo-binstall --force --color always"),
        .output("Compiling hickory-proto\n"),
    ])
    // Output only streams incrementally under a pty, which is what makes progress visible.
    #expect(runner.options.map(\.terminal) == [true])
}

@Test func installThrowsWhenCargoFails() {
    let runner = StubRunner()
    runner.status = 1
    runner.stderr = "no matching package\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/fake/cargo"])
    let absent = CargoToolchainStatus(cargo: "/fake/cargo", binstall: nil, installUpdate: nil)

    #expect(throws: CargoToolchainError.commandFailed("no matching package\n")) {
        try toolchain.install(.binstall, status: absent)
    }
}

@Test func installRequiresCargo() {
    let toolchain = CargoToolchain(runner: StubRunner(), toolPaths: [:])
    let noCargo = CargoToolchainStatus(cargo: nil, binstall: nil, installUpdate: nil)

    #expect(throws: CargoToolchainError.cargoUnavailable) {
        try toolchain.install(.binstall, status: noCargo)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PackageCommandProgress] = []

    func append(_ event: PackageCommandProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var values: [PackageCommandProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class StubRunner: CommandRunning, @unchecked Sendable {
    var stdout = ""
    var stderr = ""
    var status: Int32 = 0
    var streamedOutput = ""
    /// Commands containing this substring exit non-zero, so fallback chains can be exercised.
    var failingCommandSubstring: String?
    /// Per-command stderr, keyed by a substring — lets a chain fail twice with different messages,
    /// so a test can tell which failure was reported.
    var failingCommandStderr: [String: String] = [:]
    private let lock = NSLock()
    private var recordedCommands: [String] = []
    private var recordedOptions: [CommandRunOptions] = []

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    var options: [CommandRunOptions] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOptions
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        let command = ([executable] + arguments).joined(separator: " ")
        lock.lock()
        recordedCommands.append(command)
        recordedOptions.append(options)
        lock.unlock()
        if !streamedOutput.isEmpty { onOutput?(streamedOutput) }
        if let match = failingCommandStderr.first(where: { command.contains($0.key) }) {
            return CommandResult(stdout: "", stderr: match.value, status: 1)
        }
        if let failingCommandSubstring, command.contains(failingCommandSubstring) {
            return CommandResult(stdout: "", stderr: "no prebuilt artifact\n", status: 1)
        }
        return CommandResult(stdout: stdout, stderr: stderr, status: status)
    }
}

@Test func helperIDRoundTripsThroughItsPromptKey() {
    // The same string identifies the offer, the dismissal, and the tool to install over the host
    // notification, so a manager owns one namespace rather than three.
    for helper in CargoHelper.allCases {
        #expect(CargoHelper(promptKey: helper.promptKey) == helper)
        #expect(helper.setupOffer.id == helper.promptKey)
    }
    #expect(CargoHelper(promptKey: "homebrew.something") == nil)
}

@Test func helperIdentifiersResolveOnlyToCargosOwnHelpers() {
    // The prompt key is the whole contract between the card, the dismissal, and the host request,
    // so an identifier that is not cargo's has to resolve to nothing rather than to a guess.
    for helper in CargoHelper.allCases {
        #expect(CargoHelper(promptKey: helper.promptKey) == helper)
    }
    #expect(CargoHelper(promptKey: "homebrew.nonexistent") == nil)
    #expect(CargoHelper(promptKey: "brew:curl") == nil)
    #expect(CargoHelper.installUpdate.crateName == "cargo-update")
}

@Test func cargoOffersOnlyWhenItsOwnManagersHavePackages() {
    let none = CargoSetupState(status: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil))

    // Cargo decides what "in use" means for itself; callers just pass what is installed.
    #expect(none.offer(installedManagers: [.cargoInstall]) == .binstall)
    #expect(none.offer(installedManagers: [.rustup]) == .binstall)
    #expect(none.offer(installedManagers: [.homebrew, .npm]) == nil)
    #expect(none.offer(installedManagers: []) == nil)
}

@Test func cargoSetupSurfacesAnOfferOnlyOnceDetected() {
    // Status is stated rather than detected: on a machine that already has both helpers, real
    // detection yields no offer and every assertion below would silently be skipped.
    let state = CargoSetupState()
    #expect(state.offer(installedManagers: [.cargoInstall]) == nil, "undetected must not prompt")

    let detected = state.merging(status: neitherHelperInstalled, preferences: PackagePreferences())
    let offer = try? #require(detected.offer(installedManagers: [.cargoInstall])?.setupOffer)
    #expect(offer?.manager == .cargoInstall)
    #expect(offer?.title.isEmpty == false)
    #expect(offer?.explanation.isEmpty == false)
    #expect(offer?.symbolName.isEmpty == false)
}

@Test func cargoSetupDismissalSuppressesTheOffer() {
    var state = CargoSetupState()
        .merging(status: neitherHelperInstalled, preferences: PackagePreferences())
    #expect(state.offer(installedManagers: [.cargoInstall]) == .binstall)

    state.preferences.dismiss(CargoHelper.binstall.promptKey)

    #expect(state.offer(installedManagers: [.cargoInstall]) == .installUpdate)
    #expect(state.preferences.hasDismissed(CargoHelper.binstall.promptKey))
}

@Test func cargoSetupKeepsADismissalMadeWhileDetectionWasInFlight() {
    // Detection reads preferences from disk on a background task. Dismissing while that read is in
    // flight leaves the dismissal in memory only, and taking the loaded snapshot wholesale would
    // put the card the user just dismissed straight back. Nothing here is detected for real: this
    // has to assert unconditionally on every machine, whatever it happens to have installed.
    var state = CargoSetupState(status: neitherHelperInstalled, preferences: PackagePreferences())
    #expect(state.offer(installedManagers: [.cargoInstall]) == .binstall)
    state.preferences.dismiss(CargoHelper.binstall.promptKey)

    // The in-flight read finishes and reports preferences from before the dismissal.
    let merged = state.merging(status: neitherHelperInstalled, preferences: PackagePreferences())

    #expect(merged.preferences.hasDismissed(CargoHelper.binstall.promptKey))
    #expect(merged.offer(installedManagers: [.cargoInstall]) == .installUpdate)
}

@Test func cargoSetupPicksUpDismissalsRecordedElsewhere() {
    // The other direction: the menu bar helper and previous launches write to the same file, so a
    // dismissal arriving from disk still has to take effect.
    var stored = PackagePreferences()
    stored.dismiss(CargoHelper.binstall.promptKey)

    let merged = CargoSetupState().merging(status: neitherHelperInstalled, preferences: stored)

    #expect(merged.preferences.hasDismissed(CargoHelper.binstall.promptKey))
    #expect(merged.offer(installedManagers: [.cargoInstall]) == .installUpdate)
}

@Test func cargoSetupDistinguishesUndetectedFromNothingToOffer() {
    let undetected = CargoSetupState()
    #expect(undetected.isAwaitingDetection(installedManagers: [.cargoInstall]))
    // Nothing to wait for when the manager is not even in use.
    #expect(!undetected.isAwaitingDetection(installedManagers: [.homebrew]))
    #expect(!undetected.isAwaitingDetection(installedManagers: []))

    let detected = undetected.merging(status: neitherHelperInstalled, preferences: PackagePreferences())
    #expect(!detected.isAwaitingDetection(installedManagers: [.cargoInstall]))
}

@Test func packagePreferencesMergeUnionsDismissals() {
    var mine = PackagePreferences()
    mine.dismiss(CargoHelper.binstall.promptKey)
    var theirs = PackagePreferences()
    theirs.dismiss(CargoHelper.installUpdate.promptKey)

    let merged = mine.merging(theirs)

    #expect(merged.hasDismissed(CargoHelper.binstall.promptKey))
    #expect(merged.hasDismissed(CargoHelper.installUpdate.promptKey))
    #expect(merged == theirs.merging(mine))
}

/// Cargo present, neither helper installed — the one state in which both offers are live.
///
/// Stated rather than detected on purpose: `CargoSetupState.detect` shells out, so a test built on
/// it asserts nothing at all on a machine that already has the helpers, which is exactly where
/// these regressions would go unnoticed.
private let neitherHelperInstalled = CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)

@Test func preferencesStoreKeepsEveryDismissalUnderConcurrentWriters() {
    // Writers arriving from several queues at once must not lose each other's dismissals, whatever
    // order the reads and writes interleave in.
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-prefs-race-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = PackagePreferencesStore(url: url)
    let prompts = (0..<32).map { "cargo.race\($0)" }

    DispatchQueue.concurrentPerform(iterations: prompts.count) { index in
        var preferences = PackagePreferences()
        preferences.dismiss(prompts[index])
        store.save(preferences)
    }
    store.flush()

    let loaded = store.load()
    #expect(prompts.allSatisfy(loaded.hasDismissed))
}

@Test func installReportsWhichCommandFailedWhenEveryCommandFails() {
    // `failure` is overwritten each round, so the error the user sees is the compile's, not the
    // prebuilt download's. The compile error is the actionable one — reporting binstall's would
    // send them chasing a missing artifact when the real problem is the crate.
    let runner = StubRunner()
    runner.status = 1
    runner.stderr = "no prebuilt artifact\n"
    runner.failingCommandStderr = ["install cargo-update": "could not compile cargo-update\n"]
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/c"])
    let status = CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: nil)

    #expect(throws: CargoToolchainError.commandFailed("could not compile cargo-update\n")) {
        try toolchain.install(.installUpdate, status: status)
    }
}

@Test func installExplainsTheFallbackInItsProgressStream() throws {
    // Falling back means a multi-minute compile. The marker between the two commands is the only
    // signal the user gets that the fast path was tried and did not work.
    let runner = StubRunner()
    runner.failingCommandSubstring = "binstall"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/c"])
    let status = CargoToolchainStatus(cargo: "/c", binstall: "/b", installUpdate: nil)
    let progress = ProgressRecorder()

    try toolchain.install(.installUpdate, status: status) { progress.append($0) }

    #expect(progress.values == [
        .started(command: "cargo binstall cargo-update --no-confirm --force --locked"),
        // Between the two commands: without this the terminal jumps straight from a binstall
        // invocation to a compile with nothing explaining why.
        .output("\ncargo binstall cargo-update --no-confirm --force --locked failed.\n"),
        .started(command: "cargo install cargo-update --force --color always"),
    ])
}

@Test func aCargoUpdateFailureIsReportedRatherThanReadAsNothingToUpdate() throws {
    // An offline registry, a broken config, a held package-cache lock: cargo-update runs and fails.
    // Swallowing that empties Outdated for every crate outside the curated catalog, which the user
    // reads as "all up to date" rather than "the check did not happen".
    let runner = StubRunner()
    runner.stdout = "just v1.5.0:\n    just\n"
    runner.failingCommandStderr = ["install-update": "error: failed to query registry\n"]
    let scanner = PackageScanner(runner: runner, toolPaths: ["cargo": "/c"])
    let warnings = LockedStrings()

    let packages = try scanner.scanCargoInstall(
        database: PackageDatabase(),
        cargoStatus: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: "/u")
    ) { warnings.append($0) }

    #expect(!packages.isEmpty, "the crates themselves still scanned fine")
    #expect(warnings.values.count == 1)
    #expect(warnings.values.first?.contains("cargo-update") == true)
}

@Test func cargoUpdateSimplyNotBeingInstalledIsNotAWarning() throws {
    // The ordinary case. The offer card is how we ask about it; an error banner would be noise.
    let runner = StubRunner()
    runner.stdout = "just v1.5.0:\n    just\n"
    let scanner = PackageScanner(runner: runner, toolPaths: ["cargo": "/c"])
    let warnings = LockedStrings()

    _ = try scanner.scanCargoInstall(
        database: PackageDatabase(),
        cargoStatus: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: nil)
    ) { warnings.append($0) }

    #expect(warnings.values.isEmpty)
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

@Test func catalogMetadataFillsAMissingLatestVersionButNeverOverwritesAnObservedOne() {
    // The freshness pass enriches every scanned package with catalogued description. A crate
    // cargo-update had just reported as outdated used to drop back out of Outdated seconds later,
    // because a stale catalog claimed the installed version was the latest.
    let observed = ManagedPackage(
        manager: .cargoInstall,
        name: "just",
        installedVersion: "1.5.0",
        latestVersion: "1.57.0"
    )
    let staleCatalog = PackageMetadata(summary: "A command runner", category: nil, homepage: nil, version: "1.5.0")

    let enriched = observed.applying(metadata: staleCatalog)
    #expect(enriched.latestVersion == "1.57.0", "what cargo-update saw wins")
    #expect(enriched.isOutdated)
    #expect(enriched.summary == "A command runner", "description still comes from the catalog")

    // The other direction: a manager that cannot determine latest still gets it from the catalog.
    let unobserved = ManagedPackage(
        manager: .skills,
        name: "thing",
        installedVersion: "1.0.0",
        latestVersion: nil
    )
    #expect(unobserved.applying(metadata: PackageMetadata(summary: nil, category: nil, homepage: nil, version: "2.0.0")).latestVersion == "2.0.0")
}

@Test func aStalledCargoUpdateBecomesAWarningRatherThanAHungRefresh() throws {
    // End to end for the stall: cargo-update never answers, the scan gives up on it, the crates
    // still land, and the user is told why their updates are missing instead of watching a spinner.
    let scanner = PackageScanner(runner: StallingRunner(), toolPaths: ["cargo": "/bin/sh"])
    let warnings = LockedStrings()

    let packages = try scanner.scanCargoInstall(
        database: PackageDatabase(),
        cargoStatus: CargoToolchainStatus(cargo: "/bin/sh", binstall: nil, installUpdate: "/u")
    ) { warnings.append($0) }

    #expect(!packages.isEmpty, "the crates themselves still scanned")
    #expect(warnings.values.count == 1)
    #expect(warnings.values.first?.contains("stopped responding") == true)
}

/// Answers `install --list` immediately and hangs on `install-update`, which is the shape of a
/// registry that never replies.
private final class StallingRunner: CommandRunning, @unchecked Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        guard arguments.first == "install-update" else {
            return CommandResult(stdout: "just v1.5.0:\n    just\n", stderr: "", status: 0)
        }
        return try SystemCommandRunner().run(
            "/bin/sh",
            ["-c", "sleep 5"],
            options: CommandRunOptions(inactivityTimeout: 0.4)
        )
    }
}

@Test func cargoUpdateAsksForTheTimeoutItNeeds() throws {
    // The end-to-end stall test drives a runner that invents its own budget, so it proves the
    // timeout error becomes a warning — not that the real call site asks for a timeout at all.
    // Now that timeouts are opt-in, that distinction is the whole fix.
    let runner = StubRunner()
    runner.stdout = "Package Installed Latest Needs update\n"
    let toolchain = CargoToolchain(runner: runner, toolPaths: ["cargo": "/c"])

    _ = try toolchain.latestVersions(
        status: CargoToolchainStatus(cargo: "/c", binstall: nil, installUpdate: "/u")
    )

    #expect(runner.options.last?.inactivityTimeout == defaultQueryInactivityTimeout)
}

@Test func helpersAreFoundWhereCargoPutsThemEvenWhenThatIsNotOnPath() throws {
    // The Finder-launched, Homebrew-cargo case: `cargo install` drops the helper in its install root,
    // which is not on the host's PATH. Detection used to miss it, so a successful install reported
    // no error and then offered itself again, forever.
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pmm-cargo-home-\(UUID().uuidString)", isDirectory: true)
    let bin = home.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let binstall = bin.appendingPathComponent(CargoHelper.binstall.executableName)
    FileManager.default.createFile(atPath: binstall.path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binstall.path)

    let toolchain = CargoToolchain(
        runner: StubRunner(),
        toolPaths: ["cargo": "/c"],
        environment: ["CARGO_HOME": "/wrong/cargo-home", "CARGO_INSTALL_ROOT": home.path],
        // Nothing on PATH: this machine almost certainly has cargo-binstall installed, and finding
        // that one would mean the CARGO_HOME lookup under test never runs.
        findOnPath: { _ in nil }
    )

    #expect(toolchain.status().has(.binstall))
    // And so the updater uses it rather than compiling from source.
    #expect(toolchain.updateCommands(for: "just").first?.arguments.first == "binstall")
}
