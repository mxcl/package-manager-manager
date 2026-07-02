import Foundation
import Testing
@testable import PMMCore

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    var commands: [String] = []
    var result = CommandResult(stdout: "", stderr: "", status: 0)

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        commands.append(([executable] + arguments).joined(separator: " "))
        return result
    }
}

@Test func packageUpdaterRunsManagerCommands() throws {
    let runner = RecordingRunner()
    let updater = PackageUpdater(
        runner: runner,
        toolPaths: ["cargo": "/fake/cargo", "brew": "/fake/brew", "npm": "/fake/npm", "uv": "/fake/uv"]
    )

    try updater.update(package(.cargoInstall, "ripgrep"))
    try updater.update(package(.homebrew, "git"))
    try updater.update(package(.npm, "@scope/tool"))
    try updater.update(package(.uv, "ruff", summary: "uv-installed tool", category: "language-runtime"))
    try updater.update(package(.uv, "cpython-3.13.12-macos-aarch64-none", latestVersion: "3.13.14", summary: "uv-managed Python", category: "language-runtime"))

    #expect(runner.commands == [
        "/fake/cargo install ripgrep --force --color never",
        "/fake/brew upgrade git",
        "/fake/npm install -g @scope/tool@latest",
        "/fake/uv tool upgrade ruff --color never",
        "/fake/uv python install 3.13.14 --color never",
        "/fake/uv python uninstall cpython-3.13.12-macos-aarch64-none --color never",
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

    #expect(throws: PackageUpdateError.unsupportedManager(.npx)) {
        try updater.update(package(.npx, "acorn"))
    }
    #expect(throws: PackageUpdateError.unsupportedManager(.uvx)) {
        try updater.update(package(.uvx, "ruff"))
    }
}

private func package(
    _ manager: PackageManagerKind,
    _ name: String,
    latestVersion: String = "2.0.0",
    summary: String? = nil,
    category: String? = nil
) -> ManagedPackage {
    ManagedPackage(
        manager: manager,
        name: name,
        installedVersion: "1.0.0",
        latestVersion: latestVersion,
        summary: summary,
        category: category
    )
}
