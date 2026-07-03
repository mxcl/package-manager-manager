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

    try updater.update(package(.cargoInstall, "cargo:ripgrep", displayName: "Ripgrep"))
    try updater.update(package(.homebrew, "brew:git", displayName: "Git"))
    try updater.update(package(.npm, "npm:@scope/tool", displayName: "Scoped Tool"))
    try updater.update(package(.npx, "npx:acorn", displayName: "Acorn"))
    try updater.update(package(.uv, "uv:tool:ruff", displayName: "Ruff", summary: "uv-installed tool", category: "language-runtime"))
    try updater.update(package(.uv, "uv:cpython:3.13", displayName: "uv Managed Python 3.13", latestVersion: "3.13.14", summary: "uv-managed Python", category: "language-runtime"))

    #expect(runner.commands == [
        "/fake/cargo install ripgrep --force --color never",
        "/fake/brew upgrade git",
        "/fake/npm install -g @scope/tool@latest",
        "/fake/npm exec --yes --package acorn@2.0.0 -- true",
        "/fake/uv tool upgrade ruff --color never",
        "/fake/uv python install 3.13.14 --color never",
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

@Test func packageUpdaterRemovesOldNpxCacheEntryAfterSuccessfulUpdate() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let packageURL = home.appendingPathComponent(".npm/_npx/cache-id/node_modules/hyperframes", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let runner = RecordingRunner()
    let updater = PackageUpdater(runner: runner, homeDirectory: home, toolPaths: ["npm": "/fake/npm"])

    try updater.update(package(.npx, "npx:hyperframes", installLocation: packageURL.path))

    #expect(runner.commands == ["/fake/npm exec --yes --package hyperframes@2.0.0 -- true"])
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".npm/_npx/cache-id").path))
}

@Test func packageUpdaterThrowsOnUnsupportedManagers() throws {
    let updater = PackageUpdater()

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
    category: String? = nil,
    installLocation: String? = nil
) -> ManagedPackage {
    ManagedPackage(
        manager: manager,
        identifier: name,
        displayName: displayName,
        installedVersion: "1.0.0",
        latestVersion: latestVersion,
        summary: summary,
        category: category,
        installLocation: installLocation
    )
}
