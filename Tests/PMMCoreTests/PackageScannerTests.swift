import Foundation
import Testing
@testable import PMMCore

private struct FakeRunner: CommandRunning {
    let responses: [String: CommandResult]

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        responses[([executable] + arguments).joined(separator: " ")] ?? CommandResult(stdout: "", stderr: "", status: 0)
    }
}

@Test func cargoInstallScannerParsesInstalledCratesAndBinaryPath() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = home.appendingPathComponent(".cargo/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("rg").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: home) }

    let runner = FakeRunner(responses: [
        "/fake/cargo install --list --color never": CommandResult(stdout: """
        ripgrep v14.1.1:
            rg
        cargo-edit v0.13.0:
            cargo-add
            cargo-rm
        """, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, homeDirectory: home, toolPaths: ["cargo": "/fake/cargo"], environment: [:])

    let packages = try scanner.scanCargoInstall(database: PackageDatabase())

    #expect(packages.first == ManagedPackage(
        manager: .cargoInstall,
        name: "ripgrep",
        installedVersion: "14.1.1",
        latestVersion: nil,
        summary: "cargo-installed Rust binary",
        category: "developer-tools",
        installLocation: home.appendingPathComponent(".cargo").path,
        binaryPath: bin.appendingPathComponent("rg").path
    ))
    #expect(packages.last?.name == "cargo-edit")
    #expect(packages.last?.binaryPath == nil)
}

@Test func npmScannerUsesGlobalRootPrefixOutdatedAndPackageBinNames() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = temp.appendingPathComponent("lib/node_modules", isDirectory: true)
    let package = root.appendingPathComponent("@scope/tool", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try """
    {"name":"@scope/tool","version":"1.0.0","bin":{"tool":"cli.js"}}
    """.write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("tool").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/npm root -g": CommandResult(stdout: "\(root.path)\n", stderr: "", status: 0),
        "/fake/npm prefix -g": CommandResult(stdout: "\(temp.path)\n", stderr: "", status: 0),
        "/fake/npm ls -g --depth=0 --json": CommandResult(stdout: #"{"dependencies":{"@scope/tool":{"version":"1.0.0"}}}"#, stderr: "", status: 0),
        "/fake/npm outdated -g --json": CommandResult(stdout: #"{"@scope/tool":{"current":"1.0.0","latest":"1.2.0"}}"#, stderr: "", status: 1),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["npm": "/fake/npm"])

    let packages = try scanner.scanNPM(database: PackageDatabase(npms: [
        "@scope/tool": PackageMetadata(summary: "A scoped CLI", category: "developer-tools", homepage: nil, version: "1.2.0")
    ]))

    #expect(packages == [
        ManagedPackage(
            manager: .npm,
            name: "@scope/tool",
            installedVersion: "1.0.0",
            latestVersion: "1.2.0",
            summary: "A scoped CLI",
            category: "developer-tools",
            installLocation: package.path,
            binaryPath: bin.appendingPathComponent("tool").path
        )
    ])
}

@Test func homebrewScannerKeepsOnlyRequestedFormulaeAndCasks() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "git\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "git 2.50.0\nopenssl@3 3.5.0\n", stderr: "", status: 0),
        "/fake/brew list --versions --cask": CommandResult(stdout: "visual-studio-code 1.101.2\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let packages = try scanner.scanHomebrew(database: PackageDatabase())

    #expect(packages.map(\.name) == ["git", "visual-studio-code"])
}

@Test func npxScannerDeduplicatesCacheCopiesByPackageAndVersion() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for cacheID in ["a", "b"] {
        let package = home.appendingPathComponent(".npm/_npx/\(cacheID)/node_modules/acorn", isDirectory: true)
        let transitive = home.appendingPathComponent(".npm/_npx/\(cacheID)/node_modules/commander", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transitive, withIntermediateDirectories: true)
        try #"{"packages":{"":{"dependencies":{"acorn":"8.16.0"}}}}"#
            .write(to: home.appendingPathComponent(".npm/_npx/\(cacheID)/package-lock.json"), atomically: true, encoding: .utf8)
        try #"{"name":"acorn","version":"8.16.0"}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try #"{"name":"commander","version":"14.0.0"}"#
            .write(to: transitive.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }

    let scanner = PackageScanner(runner: FakeRunner(responses: [:]), homeDirectory: home)
    let packages = try scanner.scanNPX(database: PackageDatabase(npms: [
        "acorn": PackageMetadata(summary: nil, category: nil, homepage: nil, version: "8.17.0")
    ]))

    #expect(packages.count == 1)
    #expect(packages.first?.isOutdated == true)
    #expect(packages.first?.name == "acorn")
}

@Test func uvScannerIncludesToolsAndOnlyUvManagedPythons() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let tools = temp.appendingPathComponent("tools", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    let pythonDir = temp.appendingPathComponent("python", isDirectory: true)
    let pythonBin = pythonDir.appendingPathComponent("cpython-3.13-macos-aarch64-none/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: tools.appendingPathComponent("ruff", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pythonBin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("ruff").path, contents: Data())
    FileManager.default.createFile(atPath: pythonBin.appendingPathComponent("python3.13").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let pythonJSON = """
    [
      {"key":"cpython-3.13.12-macos-aarch64-none","version":"3.13.12","version_parts":{"major":3,"minor":13,"patch":12},"path":"\(pythonBin.appendingPathComponent("python3.13").path)","os":"macos","variant":"default","implementation":"cpython","arch":"aarch64","libc":"none"},
      {"key":"cpython-3.14.6-macos-aarch64-none","version":"3.14.6","version_parts":{"major":3,"minor":14,"patch":6},"path":"/opt/homebrew/bin/python3.14","os":"macos","variant":"default","implementation":"cpython","arch":"aarch64","libc":"none"}
    ]
    """
    let downloadJSON = """
    [
      {"key":"cpython-3.13.14-macos-aarch64-none","version":"3.13.14","version_parts":{"major":3,"minor":13,"patch":14},"path":null,"os":"macos","variant":"default","implementation":"cpython","arch":"aarch64","libc":"none"},
      {"key":"cpython-3.14.6-macos-aarch64-none","version":"3.14.6","version_parts":{"major":3,"minor":14,"patch":6},"path":null,"os":"macos","variant":"default","implementation":"cpython","arch":"aarch64","libc":"none"}
    ]
    """
    let runner = FakeRunner(responses: [
        "/fake/uv tool dir --offline --color never": CommandResult(stdout: "\(tools.path)\n", stderr: "", status: 0),
        "/fake/uv python dir --offline --color never": CommandResult(stdout: "\(pythonDir.path)\n", stderr: "", status: 0),
        "/fake/uv tool list --show-paths --show-version-specifiers --show-python --offline --color never": CommandResult(stdout: """
        ruff v0.6.9
        - ruff
          \(bin.appendingPathComponent("ruff").path)
          \(tools.appendingPathComponent("ruff").path)
        """, stderr: "", status: 0),
        "/fake/uv tool list --outdated --show-paths --show-version-specifiers --show-python --color never": CommandResult(stdout: """
        ruff v0.6.9 [latest: 0.7.0]
        - ruff
        """, stderr: "", status: 0),
        "/fake/uv python list --only-installed --output-format json --offline --color never": CommandResult(stdout: pythonJSON, stderr: "", status: 0),
        "/fake/uv python list --all-versions --only-downloads --output-format json --offline --color never": CommandResult(stdout: downloadJSON, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["uv": "/fake/uv"])

    let packages = try scanner.scanUV(database: PackageDatabase())

    #expect(packages.map(\.name) == ["ruff", "cpython-3.13.12-macos-aarch64-none"])
    #expect(packages.first?.installedVersion == "0.6.9")
    #expect(packages.first?.latestVersion == "0.7.0")
    #expect(packages.first?.installLocation == tools.appendingPathComponent("ruff").path)
    #expect(packages.first?.binaryPath == bin.appendingPathComponent("ruff").path)
    #expect(packages.last?.installedVersion == "3.13.12")
    #expect(packages.last?.latestVersion == "3.13.14")
}

@Test func uvxScannerReadsCachedToolEnvironments() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let environment = temp.appendingPathComponent("environments-v2/ruff-0123456789abcdef", isDirectory: true)
    let bin = environment.appendingPathComponent("bin", isDirectory: true)
    let distInfo = environment.appendingPathComponent("lib/python3.13/site-packages/ruff-0.6.9.dist-info", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: distInfo, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("ruff").path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("ruff").path)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/uv cache dir": CommandResult(stdout: "\(temp.path)\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["uv": "/fake/uv"])

    let packages = try scanner.scanUVX(database: PackageDatabase())

    #expect(packages.count == 1)
    #expect(packages.first?.manager == .uvx)
    #expect(packages.first?.name == "ruff")
    #expect(packages.first?.installedVersion == "0.6.9")
    #expect(packages.first?.summary == "uvx cached tool environment")
    #expect(packages.first?.category == "developer-tools")
    #expect(packages.first?.installLocation?.hasSuffix("/environments-v2/ruff-0123456789abcdef") == true)
    #expect(packages.first?.binaryPath?.hasSuffix("/environments-v2/ruff-0123456789abcdef/bin/ruff") == true)
}
