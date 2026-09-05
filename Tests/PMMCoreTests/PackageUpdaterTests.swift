import Foundation
import Testing
@testable import PMMCore

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    var commands: [String] = []
    var options: [CommandRunOptions] = []
    var streamedOutput = ""
    var result = CommandResult(stdout: "", stderr: "", status: 0)
    /// Commands containing this substring exit non-zero, so fallback chains can be exercised.
    var failingCommandSubstring: String?

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        let command = ([executable] + arguments).joined(separator: " ")
        commands.append(command)
        self.options.append(options)
        if !streamedOutput.isEmpty {
            onOutput?(streamedOutput)
        }
        if let failingCommandSubstring, command.contains(failingCommandSubstring) {
            return CommandResult(stdout: "", stderr: "no prebuilt artifact", status: 1)
        }
        return result
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

@Test func packageUpdaterRunsManagerCommands() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let pkgxRoot = temp.appendingPathComponent(".pkgx", isDirectory: true)
    try FileManager.default.createDirectory(at: pkgxRoot.appendingPathComponent("charm.sh/gum/v2.0.0"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = RecordingRunner()
    // Cargo is covered separately: which command it picks depends on whether cargo-binstall is
    // installed, which must not be read off whatever machine runs the suite.
    let updater = PackageUpdater(
        runner: runner,
        homeDirectory: temp,
        toolPaths: ["brew": "/fake/brew", "npm": "/fake/npm", "pnpm": "/fake/pnpm", "bun": "/fake/bun", "pipx": "/fake/pipx", "uv": "/fake/uv", "go": "/fake/go", "pkgx": "/fake/pkgx"],
        environment: ["PKGX_DIR": pkgxRoot.path]
    )

    try updater.update(package(.homebrew, "brew:git", displayName: "Git"))
    try updater.update(package(.npm, "npm:@scope/tool", displayName: "Scoped Tool"))
    try updater.update(package(.pnpm, "pnpm:@scope/tool", displayName: "Scoped Tool"))
    try updater.update(package(.bun, "bun:@scope/tool", displayName: "Scoped Tool"))
    try updater.update(package(.pipx, "pipx:cowsay", displayName: "cowsay"))
    try updater.update(package(.goInstall, "go:github.com/rakyll/hey", displayName: "hey"))
    try updater.update(package(.pkgx, "pkgx:charm.sh/gum", displayName: "gum"))
    try updater.update(package(.npx, "npx:acorn", displayName: "Acorn"))
    try updater.update(package(.uv, "uv:tool:ruff", displayName: "Ruff", summary: "uv-installed tool", category: "language-runtime"))
    try updater.update(package(.uv, "uv:cpython:3.13", displayName: "uv Managed Python 3.13", latestVersion: "3.13.14", summary: "uv-managed Python", category: "language-runtime"))

    #expect(runner.commands == [
        "/fake/brew upgrade git",
        "/fake/npm install -g @scope/tool@latest",
        "/fake/pnpm update -g --latest @scope/tool",
        "/fake/bun update -g --latest @scope/tool",
        "/fake/pipx upgrade cowsay",
        "/fake/go install github.com/rakyll/hey@latest",
        "/fake/pkgx +charm.sh/gum@2.0.0 true",
        "/fake/npm exec --yes --package acorn@2.0.0 -- true",
        "/fake/uv tool upgrade ruff --color always",
        "/fake/uv python install 3.13.14 --color always",
    ])
    #expect(runner.options.map(\.terminal) == Array(repeating: true, count: 10))
    #expect(runner.options.allSatisfy { $0.environment["PKGX_DIR"] == pkgxRoot.path })
}

@Test func pkgxUpdateRequiresExplicitTargetVersionAndVerifiesPresence() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = RecordingRunner()
    let updater = PackageUpdater(
        runner: runner,
        homeDirectory: temp,
        toolPaths: ["pkgx": "/fake/pkgx"],
        environment: ["PKGX_DIR": temp.path]
    )

    let gum = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        displayName: "gum",
        installedVersion: "1.0.0",
        latestVersion: "2.0.0"
    )

    #expect(throws: PackageUpdateError.self) {
        try updater.update(gum)
    }
    #expect(runner.commands == ["/fake/pkgx +charm.sh/gum@2.0.0 true"])

    let targetDir = temp.appendingPathComponent("charm.sh/gum/v2.0.0", isDirectory: true)
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
    try updater.update(gum)
    #expect(runner.commands.count == 2)
}

@Test func packageUpdaterPrefersBinstallWhenItIsInstalled() throws {
    let runner = RecordingRunner()
    let updater = PackageUpdater(
        runner: runner,
        toolPaths: ["cargo": "/fake/cargo", "cargo-binstall": "/fake/cargo-binstall"]
    )

    try updater.update(package(.cargoInstall, "cargo:ripgrep", displayName: "Ripgrep"))

    #expect(runner.commands == ["/fake/cargo binstall ripgrep --no-confirm --force --locked"])
}

@Test func packageUpdaterFallsBackToCompilingWhenBinstallFails() throws {
    let runner = RecordingRunner()
    runner.failingCommandSubstring = "binstall"
    let updater = PackageUpdater(
        runner: runner,
        toolPaths: ["cargo": "/fake/cargo", "cargo-binstall": "/fake/cargo-binstall"]
    )

    // A crate with no prebuilt artifact must still update rather than dead-ending.
    try updater.update(package(.cargoInstall, "cargo:ripgrep", displayName: "Ripgrep"))

    #expect(runner.commands == [
        "/fake/cargo binstall ripgrep --no-confirm --force --locked",
        "/fake/cargo install ripgrep --force --color always",
    ])
}

@Test func packageUpdaterReportsCommandAndOutputProgress() throws {
    let runner = RecordingRunner()
    runner.streamedOutput = "\u{1B}[32mupdated\u{1B}[0m\n"
    let updater = PackageUpdater(runner: runner, toolPaths: ["brew": "/fake/brew"])
    let progress = ProgressRecorder()

    try updater.update(package(.homebrew, "brew:git")) { event in
        progress.append(event)
    }

    #expect(progress.values == [
        .started(command: "brew upgrade git"),
        .output("\u{1B}[32mupdated\u{1B}[0m\n"),
    ])
}

@Test func packageUpdaterThrowsOnFailedCommand() throws {
    let runner = RecordingRunner()
    runner.result = CommandResult(stdout: "", stderr: "refusing\n", status: 1)
    let updater = PackageUpdater(runner: runner, toolPaths: ["brew": "/fake/brew"])

    #expect(throws: PackageUpdateError.failed("brew upgrade git", "refusing\n")) {
        try updater.update(package(.homebrew, "git"))
    }
}

@Test func packageUpdaterThrowsOnUnsupportedManagers() throws {
    let updater = PackageUpdater()

    #expect(throws: PackageUpdateError.unsupportedManager(.rustup)) {
        try updater.update(package(.rustup, "rustup:rustup"))
    }
    #expect(throws: PackageUpdateError.unsupportedManager(.uvx)) {
        try updater.update(package(.uvx, "ruff"))
    }
}

private func package(
    _ manager: PackageManagerKind,
    _ name: String,
    displayName: String? = nil,
    latestVersion: String = "2.0.0",
    summary: String? = nil,
    category: String? = nil
) -> ManagedPackage {
    ManagedPackage(
        manager: manager,
        identifier: name,
        displayName: displayName,
        installedVersion: "1.0.0",
        latestVersion: latestVersion,
        summary: summary,
        category: category
    )
}
