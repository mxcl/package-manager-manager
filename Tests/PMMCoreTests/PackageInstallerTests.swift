import Foundation
import Testing
@testable import PMMCore

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    var commands: [String] = []
    var options: [CommandRunOptions] = []
    var streamedOutput = ""
    var result = CommandResult(stdout: "", stderr: "", status: 0)

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        commands.append(([executable] + arguments).joined(separator: " "))
        self.options.append(options)
        if !streamedOutput.isEmpty {
            onOutput?(streamedOutput)
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

@Test func packageInstallerRunsManagerCommands() throws {
    let runner = RecordingRunner()
    let installer = PackageInstaller(runner: runner, toolPaths: ["brew": "/fake/brew", "npm": "/fake/npm", "pnpm": "/fake/pnpm", "bun": "/fake/bun", "pipx": "/fake/pipx", "go": "/fake/go", "pkgx": "/fake/pkgx"])

    try installer.install(package(.homebrew, "brew:git"))
    try installer.install(package(.homebrew, "brew:cask:visual-studio-code"))
    try installer.install(package(.npm, "npm:@scope/tool"))
    try installer.install(package(.pnpm, "pnpm:@scope/tool"))
    try installer.install(package(.bun, "bun:@scope/tool"))
    try installer.install(package(.pipx, "pipx:cowsay"))
    try installer.install(package(.goInstall, "go:github.com/rakyll/hey"))
    try installer.install(package(.pkgx, "pkgx:charm.sh/gum"))

    #expect(runner.commands == [
        "/fake/brew install git",
        "/fake/brew install --cask visual-studio-code",
        "/fake/npm install -g @scope/tool@latest",
        "/fake/pnpm add -g @scope/tool@latest",
        "/fake/bun add -g @scope/tool@latest",
        "/fake/pipx install cowsay",
        "/fake/go install github.com/rakyll/hey@latest",
        "/fake/pkgx +charm.sh/gum true",
    ])
    #expect(runner.options.map(\.terminal) == [true, true, true, true, true, true, true, true])
}

@Test func packageInstallerReportsCommandAndOutputProgress() throws {
    let runner = RecordingRunner()
    runner.streamedOutput = "installed\n"
    let installer = PackageInstaller(runner: runner, toolPaths: ["brew": "/fake/brew"])
    let progress = ProgressRecorder()

    try installer.install(package(.homebrew, "brew:git")) { event in
        progress.append(event)
    }

    #expect(progress.values == [
        .started(command: "brew install git"),
        .output("installed\n"),
    ])
}

@Test func packageInstallerThrowsOnFailedCommand() throws {
    let runner = RecordingRunner()
    runner.result = CommandResult(stdout: "", stderr: "refusing\n", status: 1)
    let installer = PackageInstaller(runner: runner, toolPaths: ["brew": "/fake/brew"])

    #expect(throws: PackageInstallError.failed("brew install git", "refusing\n")) {
        try installer.install(package(.homebrew, "brew:git"))
    }
}

@Test func packageInstallerRejectsUnsupportedManagers() throws {
    #expect(throws: PackageInstallError.unsupportedManager(.rustup)) {
        try PackageInstaller().install(package(.rustup, "rustup:rustup"))
    }
}

private func package(_ manager: PackageManagerKind, _ name: String) -> ManagedPackage {
    ManagedPackage(manager: manager, identifier: name, installedVersion: nil, latestVersion: "1.0.0")
}
