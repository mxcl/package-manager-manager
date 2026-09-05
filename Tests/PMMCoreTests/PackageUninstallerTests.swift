import Foundation
import Testing
@testable import PMMCore

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    var commands: [String] = []
    var options: [CommandRunOptions] = []
    var streamedOutput = ""
    var result = CommandResult(stdout: "", stderr: "", status: 0)
    var responses: [String: CommandResult] = [:]

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
        return responses[command] ?? result
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
@Test func packageUninstallerRunsManagerCommands() throws {
    let runner = RecordingRunner()
    let uninstaller = PackageUninstaller(
        runner: runner,
        toolPaths: ["cargo": "/fake/cargo", "brew": "/fake/brew", "npm": "/fake/npm", "pnpm": "/fake/pnpm", "bun": "/fake/bun", "pipx": "/fake/pipx", "uv": "/fake/uv"]
    )

    try uninstaller.uninstall(package(.cargoInstall, "cargo:ripgrep", displayName: "Ripgrep"))
    try uninstaller.uninstall(package(.homebrew, "brew:git", displayName: "Git"))
    try uninstaller.uninstall(package(.npm, "npm:@scope/tool", displayName: "Scoped Tool"))
    try uninstaller.uninstall(package(.pnpm, "pnpm:@scope/tool", displayName: "Scoped Tool"))
    try uninstaller.uninstall(package(.bun, "bun:@scope/tool", displayName: "Scoped Tool"))
    try uninstaller.uninstall(package(.pipx, "pipx:cowsay", displayName: "cowsay"))
    try uninstaller.uninstall(package(.uv, "uv:tool:ruff", displayName: "Ruff", summary: "uv-installed tool", category: "language-runtime"))
    try uninstaller.uninstall(package(.uv, "uv:cpython:3.13", displayName: "uv Managed Python 3.13", installedVersion: "3.13.12", summary: "uv-managed Python", category: "language-runtime"))

    #expect(runner.commands == [
        "/fake/cargo uninstall ripgrep --color always",
        "/fake/brew uninstall git",
        "/fake/npm uninstall -g @scope/tool",
        "/fake/pnpm remove -g @scope/tool",
        "/fake/bun remove -g @scope/tool",
        "/fake/pipx uninstall cowsay",
        "/fake/uv tool uninstall ruff --color always",
        "/fake/uv python uninstall 3.13.12 --color always",
    ])
    #expect(runner.options.map(\.terminal) == [true, true, true, true, true, true, true, true])
}

@Test func packageUninstallerRemovesGoBinary() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let goBin = temp.appendingPathComponent("go/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: goBin, withIntermediateDirectories: true)
    let binaryFile = goBin.appendingPathComponent("hey")
    FileManager.default.createFile(atPath: binaryFile.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = RecordingRunner()
    runner.responses["/fake/go version -m \(binaryFile.path)"] = CommandResult(
        stdout: "/fake/go/bin/hey: go1.27.1\n\tpath\tgithub.com/rakyll/hey\n",
        stderr: "",
        status: 0
    )
    let uninstaller = PackageUninstaller(
        runner: runner,
        homeDirectory: temp,
        toolPaths: ["go": "/fake/go"],
        environment: [:]
    )
    let pkg = ManagedPackage(
        manager: .goInstall,
        identifier: "go:github.com/rakyll/hey",
        displayName: "hey",
        installedVersion: "0.1.5",
        latestVersion: nil,
        binaryPath: binaryFile.path
    )
    #expect(FileManager.default.fileExists(atPath: binaryFile.path) == true)
    try uninstaller.uninstall(pkg)
    #expect(FileManager.default.fileExists(atPath: binaryFile.path) == false)

    // Rejection: binary outside Go bin directory
    let outsideFile = temp.appendingPathComponent("evil")
    FileManager.default.createFile(atPath: outsideFile.path, contents: Data())
    let outsidePkg = ManagedPackage(
        manager: .goInstall,
        identifier: "go:github.com/rakyll/hey",
        displayName: "evil",
        installedVersion: "0.1.5",
        latestVersion: nil,
        binaryPath: outsideFile.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(outsidePkg)
    }
    #expect(FileManager.default.fileExists(atPath: outsideFile.path) == true)

    // Rejection: binary does not match Go package
    let wrongFile = goBin.appendingPathComponent("other")
    FileManager.default.createFile(atPath: wrongFile.path, contents: Data())
    runner.responses["/fake/go version -m \(wrongFile.path)"] = CommandResult(
        stdout: "\(wrongFile.path): go1.27.1\n\tpath\tsomeone.else/tool\n",
        stderr: "",
        status: 0
    )
    let wrongPkg = ManagedPackage(
        manager: .goInstall,
        identifier: "go:github.com/rakyll/hey",
        displayName: "other",
        installedVersion: "0.1.5",
        latestVersion: nil,
        binaryPath: wrongFile.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(wrongPkg)
    }
    #expect(FileManager.default.fileExists(atPath: wrongFile.path) == true)

    // Rejection: substring / prefix match (example.com/tool-other vs example.com/tool)
    let prefixFile = goBin.appendingPathComponent("tool")
    FileManager.default.createFile(atPath: prefixFile.path, contents: Data())
    runner.responses["/fake/go version -m \(prefixFile.path)"] = CommandResult(
        stdout: "\(prefixFile.path): go1.27.1\n\tpath\texample.com/tool-other\n",
        stderr: "",
        status: 0
    )
    let prefixPkg = ManagedPackage(
        manager: .goInstall,
        identifier: "go:example.com/tool",
        displayName: "tool",
        installedVersion: "1.0.0",
        latestVersion: nil,
        binaryPath: prefixFile.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(prefixPkg)
    }
    #expect(FileManager.default.fileExists(atPath: prefixFile.path) == true)

    // Rejection: target is a directory
    let dirTarget = goBin.appendingPathComponent("dir_binary", isDirectory: true)
    try FileManager.default.createDirectory(at: dirTarget, withIntermediateDirectories: true)
    let dirPkg = ManagedPackage(
        manager: .goInstall,
        identifier: "go:example.com/dir_binary",
        displayName: "dir_binary",
        installedVersion: "1.0.0",
        latestVersion: nil,
        binaryPath: dirTarget.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(dirPkg)
    }
    #expect(FileManager.default.fileExists(atPath: dirTarget.path) == true)

    // Rejection: Go binary is unavailable
    let fileForMissingGo = goBin.appendingPathComponent("still_there")
    FileManager.default.createFile(atPath: fileForMissingGo.path, contents: Data())
    let uninstallerWithoutGo = PackageUninstaller(
        runner: runner,
        homeDirectory: temp,
        toolPaths: ["go": ""],
        environment: [:]
    )
    let missingGoPkg = ManagedPackage(
        manager: .goInstall,
        identifier: "go:example.com/still_there",
        displayName: "still_there",
        installedVersion: "1.0.0",
        latestVersion: nil,
        binaryPath: fileForMissingGo.path
    )
    #expect(throws: PackageUninstallError.missingExecutable("go")) {
        try uninstallerWithoutGo.uninstall(missingGoPkg)
    }
    #expect(FileManager.default.fileExists(atPath: fileForMissingGo.path) == true)
}

@Test func packageUninstallerReportsCommandAndOutputProgress() throws {
    let runner = RecordingRunner()
    runner.streamedOutput = "removed\n"
    let uninstaller = PackageUninstaller(runner: runner, toolPaths: ["brew": "/fake/brew"])
    let progress = ProgressRecorder()

    try uninstaller.uninstall(package(.homebrew, "brew:git")) { event in
        progress.append(event)
    }

    #expect(progress.values == [
        .started(command: "brew uninstall git"),
        .output("removed\n"),
    ])
}

@Test func packageUninstallerRemovesNpxCacheEntry() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let packageURL = home.appendingPathComponent(".npm/_npx/cache-id/node_modules/acorn", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try PackageUninstaller(homeDirectory: home).uninstall(package(.npx, "acorn", installLocation: packageURL.path))

    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".npm/_npx/cache-id").path))
}

@Test func packageUninstallerRemovesSkillsWithInstalledCLIOrNPX() throws {
    let directRunner = RecordingRunner()
    let direct = PackageUninstaller(runner: directRunner, toolPaths: ["skills": "/fake/skills"])
    try direct.uninstall(package(.skills, "skills:global:local-skill"))

    let npxRunner = RecordingRunner()
    let fallback = PackageUninstaller(runner: npxRunner, toolPaths: ["npx": "/fake/npx"])
    try fallback.uninstall(package(.skills, "skills:global:global-skill"))

    #expect(directRunner.commands == ["/fake/skills remove local-skill --global --yes"])
    #expect(npxRunner.commands == ["/fake/npx --yes skills remove global-skill --global --yes"])
}

@Test func packageUninstallerRejectsProjectSkills() throws {
    let package = package(.skills, "skills:project:local-skill")

    #expect(!PackageUninstaller.supports(package))
    #expect(throws: PackageUninstallError.unsupportedManager(.skills)) {
        try PackageUninstaller().uninstall(package)
    }
}

@Test func packageUninstallerThrowsOnFailedCommand() throws {
    let runner = RecordingRunner()
    runner.result = CommandResult(stdout: "", stderr: "refusing\n", status: 1)
    let uninstaller = PackageUninstaller(runner: runner, toolPaths: ["brew": "/fake/brew"])

    #expect(throws: PackageUninstallError.failed("brew uninstall git", "refusing\n")) {
        try uninstaller.uninstall(package(.homebrew, "git"))
    }
}

@Test func pkgxUninstallerRemovesPackageAndPrunesEmptyProjectDirectory() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectDir = temp.appendingPathComponent("charm.sh/gum", isDirectory: true)
    let v2Dir = projectDir.appendingPathComponent("v2.0.0", isDirectory: true)
    let v1Dir = projectDir.appendingPathComponent("v1.0.0", isDirectory: true)
    try FileManager.default.createDirectory(at: v2Dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: v1Dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let uninstaller = PackageUninstaller(
        runner: RecordingRunner(),
        homeDirectory: temp,
        toolPaths: ["pkgx": "/fake/pkgx"],
        environment: ["PKGX_DIR": temp.path]
    )
    let v2Pkg = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        displayName: "gum",
        installedVersion: "2.0.0",
        latestVersion: nil,
        installLocation: v2Dir.path
    )
    let v1Pkg = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        displayName: "gum",
        installedVersion: "1.0.0",
        latestVersion: nil,
        installLocation: v1Dir.path
    )

    #expect(PackageUninstaller.supports(v2Pkg))
    #expect(FileManager.default.fileExists(atPath: v2Dir.path))
    #expect(FileManager.default.fileExists(atPath: v1Dir.path))

    // Remove v2.0.0 - v1.0.0 still exists, so charm.sh/gum remains
    try uninstaller.uninstall(v2Pkg)
    #expect(!FileManager.default.fileExists(atPath: v2Dir.path))
    #expect(FileManager.default.fileExists(atPath: v1Dir.path))
    #expect(FileManager.default.fileExists(atPath: projectDir.path))

    // Remove v1.0.0 - no other versions exist, so charm.sh/gum is pruned
    try uninstaller.uninstall(v1Pkg)
    #expect(!FileManager.default.fileExists(atPath: v1Dir.path))
    #expect(!FileManager.default.fileExists(atPath: projectDir.path))

    // Rejection: target outside PKGX_DIR
    let outsideDir = temp.appendingPathComponent("outside/charm.sh/gum/v1.0.0", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    let outsidePkg = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        displayName: "gum",
        installedVersion: "1.0.0",
        latestVersion: nil,
        installLocation: outsideDir.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(outsidePkg)
    }
    #expect(FileManager.default.fileExists(atPath: outsideDir.path))

    // Rejection: target is not a directory
    let fileTarget = temp.appendingPathComponent("charm.sh/gum/v3.0.0")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: fileTarget.path, contents: Data())
    let filePkg = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        displayName: "gum",
        installedVersion: "3.0.0",
        latestVersion: nil,
        installLocation: fileTarget.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(filePkg)
    }
    #expect(FileManager.default.fileExists(atPath: fileTarget.path))

    // Rejection: target path does not match package identifier
    let otherDir = temp.appendingPathComponent("other.org/tool/v1.0.0", isDirectory: true)
    try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    let mismatchedPkg = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        displayName: "gum",
        installedVersion: "1.0.0",
        latestVersion: nil,
        installLocation: otherDir.path
    )
    #expect(throws: PackageUninstallError.self) {
        try uninstaller.uninstall(mismatchedPkg)
    }
    #expect(FileManager.default.fileExists(atPath: otherDir.path))

    // Rejection: missing executable pkgx
    let uninstallerWithoutPkgx = PackageUninstaller(
        runner: RecordingRunner(),
        homeDirectory: temp,
        toolPaths: ["pkgx": ""],
        environment: ["PKGX_DIR": temp.path]
    )
    #expect(throws: PackageUninstallError.missingExecutable("pkgx")) {
        try uninstallerWithoutPkgx.uninstall(mismatchedPkg)
    }
}

@Test func packageUninstallerDoesNotSupportRustup() throws {
    let package = package(.rustup, "rustup:rustup")

    #expect(!PackageUninstaller.supports(package))
    #expect(throws: PackageUninstallError.unsupportedManager(.rustup)) {
        try PackageUninstaller().uninstall(package)
    }
}

private func package(
    _ manager: PackageManagerKind,
    _ name: String,
    displayName: String? = nil,
    installedVersion: String = "1.0.0",
    summary: String? = nil,
    category: String? = nil,
    installLocation: String? = nil
) -> ManagedPackage {
    ManagedPackage(
        manager: manager,
        identifier: name,
        displayName: displayName,
        installedVersion: installedVersion,
        latestVersion: "1.0.0",
        summary: summary,
        category: category,
        installLocation: installLocation
    )
}
