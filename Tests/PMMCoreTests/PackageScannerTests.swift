import Foundation
import Testing
@testable import PMMCore

private struct FakeRunner: CommandRunning {
    let responses: [String: CommandResult]

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        responses[([executable] + arguments).joined(separator: " ")] ?? CommandResult(stdout: "", stderr: "", status: 0)
    }
}

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: CommandResult]
    private var storedCalls: [(command: String, options: CommandRunOptions)] = []

    var calls: [(command: String, options: CommandRunOptions)] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    init(responses: [String: CommandResult]) {
        self.responses = responses
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
        storedCalls.append((command, options))
        lock.unlock()
        return responses[command] ?? CommandResult(stdout: "", stderr: "", status: 0)
    }
}

private final class GatedRunner: CommandRunning, @unchecked Sendable {
    private let cargoGate = DispatchSemaphore(value: 0)

    func releaseCargo() {
        cargoGate.signal()
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        switch ([executable] + arguments).joined(separator: " ") {
        case "/fake/cargo install --list --color never":
            cargoGate.wait()
            return CommandResult(stdout: "ripgrep v14.1.1:\n    rg\n", stderr: "", status: 0)
        case "/fake/rustup --version":
            return CommandResult(stdout: "rustup 1.29.0\n", stderr: "", status: 0)
        case "/fake/rustup toolchain list -v":
            return CommandResult(stdout: "", stderr: "", status: 0)
        default:
            return CommandResult(stdout: "", stderr: "", status: 0)
        }
    }
}

private struct ErrorRunner: CommandRunning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "cargo failed" }
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        if executable == "/fake/cargo" { throw Failure() }
        if arguments == ["--version"] {
            return CommandResult(stdout: "rustup 1.29.0\n", stderr: "", status: 0)
        }
        return CommandResult(stdout: "", stderr: "", status: 0)
    }
}

private final class NPMResolveRunner: CommandRunning, @unchecked Sendable {
    let version: String?
    let status: Int32

    init(version: String?, status: Int32 = 0) {
        self.version = version
        self.status = status
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        if status == 0, let version, let prefix = arguments.firstIndex(of: "--prefix").map({ arguments[arguments.index(after: $0)] }) {
            let lock = URL(fileURLWithPath: prefix).appendingPathComponent("package-lock.json")
            try #"{"packages":{"\#(prefix)/node_modules/acorn":{"version":"\#(version)"}}}"#
                .write(to: lock, atomically: true, encoding: .utf8)
        }
        return CommandResult(stdout: "", stderr: "", status: status)
    }
}

private final class NPMRegistryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.responses[request.url?.path ?? ""] ?? Data()
        let status = data.isEmpty ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class EmptyNPMRegistryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.responses[request.url?.path ?? ""] ?? Data()
        let status = data.isEmpty ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
        identifier: "cargo:ripgrep",
        displayName: "ripgrep",
        installedVersion: "14.1.1",
        latestVersion: nil,
        summary: "cargo-installed Rust binary",
        category: "developer-tools",
        installLocation: home.appendingPathComponent(".cargo").path,
        binaryPath: bin.appendingPathComponent("rg").path
    ))
    #expect(packages.last?.identifier == "cargo:cargo-edit")
    #expect(packages.last?.displayName == "cargo-edit")
    #expect(packages.last?.binaryPath == nil)
}

@Test func cargoInstallScannerReceivesTheShellInstallRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pmm-cargo-root-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cargo = root.appendingPathComponent("cargo")
    try """
    #!/bin/sh
    if [ "$CARGO_INSTALL_ROOT" = "\(root.path)" ]; then
      printf 'shell-crate v1.2.3:\n    shell-crate\n'
    fi
    """.write(to: cargo, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cargo.path)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("shell-crate").path, contents: Data())

    let resolved = ["PATH": "/usr/bin:/bin", "CARGO_INSTALL_ROOT": root.path]
    let shell = ShellEnvironment { resolved }
    let runner = SystemCommandRunner(
        shellEnvironment: shell,
        inheritedEnvironment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    )
    let scanner = PackageScanner(
        runner: runner,
        toolPaths: ["cargo": cargo.path],
        environment: resolved
    )

    let packages = try scanner.scanCargoInstall(
        database: PackageDatabase(),
        cargoStatus: CargoToolchainStatus(cargo: cargo.path, binstall: nil, installUpdate: nil)
    )

    #expect(packages.map(\.identifier) == ["cargo:shell-crate"])
    #expect(packages.first?.installLocation == root.path)
    #expect(packages.first?.binaryPath == bin.appendingPathComponent("shell-crate").path)
}

@Test func miseScannerIncludesAllInstalledTools() throws {
    let json = #"{"node":[{"version":"20.19.4","install_path":"/mise/node/20.19.4"},{"version":"22.17.0","install_path":"/mise/node/22.17.0"}],"python":[{"version":"3.13.5","install_path":"/mise/python/3.13.5"}]}"#
    let runner = RecordingRunner(responses: [
        "/fake/mise ls --installed --json": CommandResult(stdout: json, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["mise": "/fake/mise"], environment: [:])

    let packages = try scanner.scanMise(database: PackageDatabase())

    #expect(runner.calls.map(\.command) == ["/fake/mise ls --installed --json"])
    #expect(packages.map(\.identifier) == ["mise:node", "mise:python"])
    #expect(packages.map(\.displayName) == ["Node.js", "Python"])
    #expect(packages.first?.installedVersions == ["22.17.0", "20.19.4"])
    #expect(packages.first?.latestVersion == nil)
    #expect(packages.first?.binaryPath == "/mise/node/22.17.0/bin/node")
    #expect(packages.last?.binaryPath == "/mise/python/3.13.5/bin/python3")
}

@Test func localMiseScanUsesTheSameInstalledOnlyCommand() async {
    let runner = RecordingRunner(responses: [
        "/fake/mise ls --installed --json": CommandResult(stdout: "{}", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["mise": "/fake/mise"], environment: [:])

    for await _ in scanner.results(for: [.mise], database: PackageDatabase(), mode: .local) {}

    #expect(runner.calls.map(\.command) == ["/fake/mise ls --installed --json"])
}

@Test(.timeLimit(.minutes(1))) func managerScanResultsYieldInCompletionOrder() async throws {
    let runner = GatedRunner()
    let scanner = PackageScanner(
        runner: runner,
        toolPaths: ["cargo": "/fake/cargo", "rustup": "/fake/rustup"],
        environment: [:]
    )
    var iterator = scanner.results(
        for: [.cargoInstall, .rustup],
        database: PackageDatabase(),
        mode: .local
    ).makeAsyncIterator()
    defer { runner.releaseCargo() }

    let first = await iterator.next()
    #expect(first?.manager == .rustup)
    runner.releaseCargo()
    let second = await iterator.next()
    #expect(second?.manager == .cargoInstall)
    #expect(await iterator.next() == nil)
}

@Test func managerScanFailureDoesNotDiscardOtherResults() async {
    let scanner = PackageScanner(
        runner: ErrorRunner(),
        toolPaths: ["cargo": "/fake/cargo", "rustup": "/fake/rustup"],
        environment: [:]
    )
    var results: [PackageManagerKind: PackageManagerScanResult] = [:]
    for await result in scanner.results(
        for: [.cargoInstall, .rustup],
        database: PackageDatabase(),
        mode: .local
    ) {
        results[result.manager] = result
    }

    #expect(results[.cargoInstall]?.packages.isEmpty == true)
    #expect(results[.cargoInstall]?.errors == ["cargo failed"])
    #expect(results[.rustup]?.packages.first?.identifier == "rustup:rustup")
    #expect(results[.rustup]?.errors.isEmpty == true)
}

@Test func localManagerScansSkipFreshnessCommands() async {
    let responses = [
        "/fake/brew --prefix": CommandResult(stdout: "/fake/homebrew\n", stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/npm ls -g --depth=0 --json": CommandResult(stdout: #"{"dependencies":{}}"#, stderr: "", status: 0),
        "/fake/uv tool list --show-paths --show-version-specifiers --show-python --offline --color never": CommandResult(stdout: "", stderr: "", status: 0),
    ]
    let runner = RecordingRunner(responses: responses)
    let scanner = PackageScanner(
        runner: runner,
        toolPaths: ["brew": "/fake/brew", "npm": "/fake/npm", "uv": "/fake/uv"],
        environment: [:]
    )
    var managers = Set<PackageManagerKind>()
    for await result in scanner.results(for: [.homebrew, .npm, .uv], database: PackageDatabase(), mode: .local) {
        managers.insert(result.manager)
    }

    let calls = runner.calls.map(\.command)
    #expect(managers == [.homebrew, .npm, .uv])
    #expect(!calls.contains("/fake/brew outdated --json=v2"))
    #expect(!calls.contains("/fake/npm outdated -g --json"))
    #expect(!calls.contains("/fake/uv tool list --outdated --show-paths --show-version-specifiers --show-python --color never"))
}

@Test func freshManagerScansRunFreshnessCommands() async {
    let runner = RecordingRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/npm ls -g --depth=0 --json": CommandResult(stdout: #"{"dependencies":{}}"#, stderr: "", status: 0),
        "/fake/npm outdated -g --json": CommandResult(stdout: #"{}"#, stderr: "", status: 0),
        "/fake/uv tool list --show-paths --show-version-specifiers --show-python --offline --color never": CommandResult(stdout: "", stderr: "", status: 0),
        "/fake/uv tool list --outdated --show-paths --show-version-specifiers --show-python --color never": CommandResult(stdout: "", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(
        runner: runner,
        toolPaths: ["brew": "/fake/brew", "npm": "/fake/npm", "uv": "/fake/uv"],
        environment: [:]
    )
    for await _ in scanner.results(for: [.homebrew, .npm, .uv], database: PackageDatabase(), mode: .fresh) {}

    let calls = Set(runner.calls.map(\.command))
    #expect(calls.contains("/fake/brew outdated --json=v2"))
    #expect(calls.contains("/fake/npm outdated -g --json"))
    #expect(calls.contains("/fake/uv tool list --outdated --show-paths --show-version-specifiers --show-python --color never"))
}

@Test func rustupScannerAddsRustupAndInstalledToolchains() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stable = home.appendingPathComponent(".rustup/toolchains/stable-aarch64-apple-darwin", isDirectory: true)
    let pinned = home.appendingPathComponent(".rustup/toolchains/1.92.0-aarch64-apple-darwin", isDirectory: true)
    try FileManager.default.createDirectory(at: stable.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: stable.appendingPathComponent("bin/rustc").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: home) }

    let runner = FakeRunner(responses: [
        "/fake/rustup --version": CommandResult(stdout: "rustup 1.29.0 (28d1352db 2026-03-05)\n", stderr: "", status: 0),
        "/fake/rustup toolchain list -v": CommandResult(stdout: """
        stable-aarch64-apple-darwin (active, default) \(stable.path)
        1.92.0-aarch64-apple-darwin \(pinned.path)
        """, stderr: "", status: 0),
        "/fake/rustup run stable-aarch64-apple-darwin rustc --version": CommandResult(stdout: "rustc 1.96.1 (31fca3adb 2026-06-26)\n", stderr: "", status: 0),
        "/fake/rustup run 1.92.0-aarch64-apple-darwin rustc --version": CommandResult(stdout: "rustc 1.92.0 (abcd 2026-01-01)\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["rustup": "/fake/rustup"])

    let packages = try scanner.scanRustup(database: PackageDatabase())

    #expect(packages == [
        ManagedPackage(
            manager: .rustup,
            identifier: "rustup:rustup",
            displayName: "rustup",
            installedVersion: "1.29.0",
            latestVersion: nil,
            summary: "Rust toolchain installer",
            category: "developer-tools",
            homepage: "https://rustup.rs/",
            docs: "https://rust-lang.github.io/rustup/",
            repo: "https://github.com/rust-lang/rustup",
            installLocation: "/fake",
            binaryPath: "/fake/rustup"
        ),
        ManagedPackage(
            manager: .rustup,
            identifier: "rustup:toolchain:stable-aarch64-apple-darwin",
            displayName: "rust stable ²",
            installedVersion: "1.96.1",
            latestVersion: nil,
            summary: "rustup managed Rust toolchain",
            category: "language-runtime",
            homepage: "https://rustup.rs/",
            docs: "https://rust-lang.github.io/rustup/",
            repo: "https://github.com/rust-lang/rustup",
            installLocation: stable.path,
            binaryPath: stable.appendingPathComponent("bin/rustc").path
        ),
        ManagedPackage(
            manager: .rustup,
            identifier: "rustup:toolchain:1.92.0-aarch64-apple-darwin",
            displayName: "rust 1.92.0 ²",
            installedVersion: "1.92.0",
            latestVersion: nil,
            summary: "rustup managed Rust toolchain",
            category: "language-runtime",
            homepage: "https://rustup.rs/",
            docs: "https://rust-lang.github.io/rustup/",
            repo: "https://github.com/rust-lang/rustup",
            installLocation: pinned.path,
            binaryPath: nil
        )
    ])
}

@Test func npmScannerUsesGlobalRootPrefixOutdatedAndPackageBinNames() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = temp.appendingPathComponent("lib/node_modules", isDirectory: true)
    let package = root.appendingPathComponent("@scope/tool", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try #"""
    {"name":"@scope/tool","version":"1.0.0","description":"A scoped CLI","homepage":"https://example.com/tool","repository":{"url":"git+https://github.com/example/tool.git"},"bin":{"tool":"cli.js"}}
    """#
        .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
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
        "@scope/tool": PackageMetadata(summary: "Ignored db summary", category: "developer-tools", homepage: nil, version: "9.9.9")
    ]))

    #expect(packages == [
        ManagedPackage(
            manager: .npm,
            identifier: "npm:@scope/tool",
            displayName: "@scope/tool",
            installedVersion: "1.0.0",
            latestVersion: "1.2.0",
            summary: "A scoped CLI",
            category: "developer-tools",
            homepage: "https://example.com/tool",
            repo: "https://github.com/example/tool",
            installLocation: package.path,
            binaryPath: bin.appendingPathComponent("tool").path
        )
    ])
}

@Test func pnpmScannerUsesGlobalRootBinOutdatedAndPackageBinNames() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let globalDir = temp.appendingPathComponent("pnpm/global/5", isDirectory: true)
    let package = globalDir.appendingPathComponent("node_modules/@scope/pnpm-tool", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try #"""
    {"name":"@scope/pnpm-tool","version":"2.0.0","description":"A pnpm CLI","homepage":"https://example.com/pnpm-tool","repository":{"url":"git+https://github.com/example/pnpm-tool.git"},"bin":{"pnpm-tool":"cli.js"}}
    """#
        .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("pnpm-tool").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let pnpmListJSON = #"""
    [
      {
        "name": "global-packages",
        "version": "1.0.0",
        "path": "\#(globalDir.path)",
        "dependencies": {
          "@scope/pnpm-tool": {
            "from": "@scope/pnpm-tool",
            "version": "2.0.0",
            "path": "\#(package.path)"
          }
        }
      }
    ]
    """#

    let runner = FakeRunner(responses: [
        "/fake/pnpm bin -g": CommandResult(stdout: "\(bin.path)\n", stderr: "", status: 0),
        "/fake/pnpm root -g": CommandResult(stdout: "\(globalDir.appendingPathComponent("node_modules").path)\n", stderr: "", status: 0),
        "/fake/pnpm list -g --depth=0 --json": CommandResult(stdout: pnpmListJSON, stderr: "", status: 0),
        "/fake/pnpm outdated -g --json": CommandResult(stdout: #"{"@scope/pnpm-tool":{"current":"2.0.0","latest":"2.5.0"}}"#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["pnpm": "/fake/pnpm"])

    let packages = try scanner.scanPNPM(database: PackageDatabase(npms: [
        "@scope/pnpm-tool": PackageMetadata(summary: "Ignored db summary", category: "developer-tools", homepage: nil, version: "9.9.9")
    ]))

    #expect(packages == [
        ManagedPackage(
            manager: .pnpm,
            identifier: "pnpm:@scope/pnpm-tool",
            displayName: "@scope/pnpm-tool",
            installedVersion: "2.0.0",
            latestVersion: "2.5.0",
            summary: "A pnpm CLI",
            category: "developer-tools",
            homepage: "https://example.com/pnpm-tool",
            repo: "https://github.com/example/pnpm-tool",
            installLocation: package.path,
            binaryPath: bin.appendingPathComponent("pnpm-tool").path
        )
    ])
}

@Test func goParsingHelpersParseVersionAndListJSON() {
    let versionOutput = """
    /Users/test/go/bin/goimports: go1.27.1
    \tpath\tgolang.org/x/tools/cmd/goimports
    \tmod\tgolang.org/x/tools\tv0.49.0\th1:abc
    \tdep\tgolang.org/x/mod\tv0.39.0
    /Users/test/go/bin/hey: go1.27.1
    \tpath\tgithub.com/rakyll/hey
    \tmod\tgithub.com/rakyll/hey\tv0.1.5\th1:def
    """
    let packages = PackageScanner.parseGoVersionList(versionOutput, latestVersions: [
        "golang.org/x/tools": "v0.50.0",
        "github.com/rakyll/hey": "0.1.5",
    ])
    #expect(packages.count == 2)
    let goimports = packages.first { $0.displayName == "goimports" }
    #expect(goimports?.identifier == "go:golang.org/x/tools/cmd/goimports")
    #expect(goimports?.catalogIdentifier == "go:golang.org/x/tools")
    #expect(goimports?.installedVersion == "0.49.0")
    #expect(goimports?.latestVersion == "0.50.0")
    #expect(goimports?.homepage == "https://pkg.go.dev/golang.org/x/tools/cmd/goimports")
    #expect(goimports?.repo == "https://github.com/golang/tools")
    #expect(goimports?.binaryPath == "/Users/test/go/bin/goimports")

    let hey = packages.first { $0.displayName == "hey" }
    #expect(hey?.identifier == "go:github.com/rakyll/hey")
    #expect(hey?.catalogIdentifier == nil)
    #expect(hey?.installedVersion == "0.1.5")
    #expect(hey?.latestVersion == "0.1.5")
    #expect(hey?.repo == "https://github.com/rakyll/hey")

    let modules = PackageScanner.extractGoModules(from: versionOutput)
    #expect(modules == ["github.com/rakyll/hey", "golang.org/x/tools"])

    let listJson = """
    {
    \t"Path": "golang.org/x/tools",
    \t"Version": "v0.50.0"
    }
    {
    \t"Path": "github.com/rakyll/hey",
    \t"Version": "v0.1.5",
    \t"Origin": {
    \t\t"VCS": "git",
    \t\t"URL": "https://github.com/rakyll/hey",
    \t\t"Hash": "e64ec7a3ad1ef8bc828fe61e1fb324cc2e74c604",
    \t\t"TagSum": "t1:3zLLgy63FyJTpPNswo1aLBXp/0aV52j65uGmbmFDIkI=",
    \t\t"Ref": "refs/tags/v0.1.5"
    \t}
    }
    """
    let parsedLatest = PackageScanner.parseGoListJSON(listJson)
    #expect(parsedLatest["golang.org/x/tools"] == "0.50.0")
    #expect(parsedLatest["github.com/rakyll/hey"] == "0.1.5")
}

@Test func goInstallScannerParsesBinariesAndMetadata() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let binaryFile = bin.appendingPathComponent("hey")
    FileManager.default.createFile(atPath: binaryFile.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let versionOutput = """
    \(binaryFile.path): go1.27.1
    \tpath\tgithub.com/rakyll/hey
    \tmod\tgithub.com/rakyll/hey\tv0.1.5\th1:abc
    """
    let runner = FakeRunner(responses: [
        "/fake/go env GOBIN GOPATH": CommandResult(stdout: "\(bin.path)\n\(temp.path)\n", stderr: "", status: 0),
        "/fake/go version -m \(binaryFile.path)": CommandResult(stdout: versionOutput, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["go": "/fake/go"], environment: [:])
    let packages = try scanner.scanGoInstall(database: PackageDatabase())

    #expect(packages == [
        ManagedPackage(
            manager: .goInstall,
            identifier: "go:github.com/rakyll/hey",
            displayName: "hey",
            installedVersion: "0.1.5",
            latestVersion: nil,
            summary: "github.com/rakyll/hey",
            category: "developer-tools",
            homepage: "https://pkg.go.dev/github.com/rakyll/hey",
            docs: "https://pkg.go.dev/github.com/rakyll/hey",
            repo: "https://github.com/rakyll/hey",
            installLocation: binaryFile.path,
            binaryPath: binaryFile.path
        )
    ])
}

@Test func goInstallScannerSurvivesUnrelatedNonGoBinaryAndQueriesModuleFreshness() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let goimportsBinary = bin.appendingPathComponent("goimports")
    let scriptBinary = bin.appendingPathComponent("script.sh")
    FileManager.default.createFile(atPath: goimportsBinary.path, contents: Data())
    FileManager.default.createFile(atPath: scriptBinary.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let versionOutput = """
    \(goimportsBinary.path): go1.27.1
    \tpath\tgolang.org/x/tools/cmd/goimports
    \tmod\tgolang.org/x/tools\tv0.49.0\th1:abc
    \(scriptBinary.path): unrecognized file format
    """
    let listOutput = """
    {
        "Path": "golang.org/x/tools",
        "Version": "v0.50.0"
    }
    """

    let runner = FakeRunner(responses: [
        "/fake/go env GOBIN GOPATH": CommandResult(stdout: "\(bin.path)\n\(temp.path)\n", stderr: "", status: 0),
        // Aggregate status 1 because of script.sh, but stdout has valid goimports info
        "/fake/go version -m \(goimportsBinary.path) \(scriptBinary.path)": CommandResult(stdout: versionOutput, stderr: "error", status: 1),
        "/fake/go version -m \(scriptBinary.path) \(goimportsBinary.path)": CommandResult(stdout: versionOutput, stderr: "error", status: 1),
        // Queries module path (golang.org/x/tools) rather than package path (golang.org/x/tools/cmd/goimports)
        "/fake/go list -m -json golang.org/x/tools@latest": CommandResult(stdout: listOutput, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["go": "/fake/go"], environment: [:])
    let packages = try scanner.scanGoInstall(database: PackageDatabase())

    #expect(packages.count == 1)
    let pkg = try #require(packages.first)
    #expect(pkg.displayName == "goimports")
    #expect(pkg.identifier == "go:golang.org/x/tools/cmd/goimports")
    #expect(pkg.catalogIdentifier == "go:golang.org/x/tools")
    #expect(pkg.installedVersion == "0.49.0")
    #expect(pkg.latestVersion == "0.50.0")
    #expect(pkg.isOutdated == true)
}

@Test func goInstallScannerConsolidatesDuplicateBinariesForSamePackage() throws {
    let versionOutput = """
    /bin/hey: go1.27.1
    \tpath\tgithub.com/rakyll/hey
    \tmod\tgithub.com/rakyll/hey\tv0.1.5\th1:abc
    /bin/hey_copy: go1.27.1
    \tpath\tgithub.com/rakyll/hey
    \tmod\tgithub.com/rakyll/hey\tv0.1.5\th1:abc
    """
    let packages = PackageScanner.parseGoVersionList(versionOutput)
    #expect(packages.count == 1)
    let pkg = try #require(packages.first)
    #expect(pkg.identifier == "go:github.com/rakyll/hey")
    #expect(Set(pkg.executableNames) == ["hey", "hey_copy"])
}

@Test func goInstallScannerHonorsEffectiveEnvironmentAndGOPATHList() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let gopath1 = temp.appendingPathComponent("gp1", isDirectory: true)
    let gopath2 = temp.appendingPathComponent("gp2", isDirectory: true)
    let bin1 = gopath1.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin1, withIntermediateDirectories: true)
    let binaryFile = bin1.appendingPathComponent("tool")
    FileManager.default.createFile(atPath: binaryFile.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let versionOutput = """
    \(binaryFile.path): go1.27.1
    \tpath\texample.com/tool
    """
    let runner = FakeRunner(responses: [
        "/fake/go version -m \(binaryFile.path)": CommandResult(stdout: versionOutput, stderr: "", status: 0),
    ])
    // Injected environment with multi-entry GOPATH
    let scanner = PackageScanner(
        runner: runner,
        toolPaths: ["go": "/fake/go"],
        environment: ["GOPATH": "\(gopath1.path):\(gopath2.path)"]
    )
    let packages = try scanner.scanGoInstall(database: PackageDatabase())
    #expect(packages.count == 1)
    #expect(packages.first?.displayName == "tool")
    #expect(packages.first?.identifier == "go:example.com/tool")
}

@Test func pnpmScannerResolvesScopedPackageWithStringBinToUnscopedBasename() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let globalDir = temp.appendingPathComponent("pnpm/global/5", isDirectory: true)
    let package = globalDir.appendingPathComponent("node_modules/@scope/my-cli", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try #"""
    {"name":"@scope/my-cli","version":"1.0.0","bin":"cli.js"}
    """#
        .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("my-cli").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let pnpmListJSON = #"""
    [
      {
        "name": "global-packages",
        "version": "1.0.0",
        "path": "\#(globalDir.path)",
        "dependencies": {
          "@scope/my-cli": {
            "from": "@scope/my-cli",
            "version": "1.0.0",
            "path": "\#(package.path)"
          }
        }
      }
    ]
    """#

    let runner = FakeRunner(responses: [
        "/fake/pnpm bin -g": CommandResult(stdout: "\(bin.path)\n", stderr: "", status: 0),
        "/fake/pnpm root -g": CommandResult(stdout: "\(globalDir.appendingPathComponent("node_modules").path)\n", stderr: "", status: 0),
        "/fake/pnpm list -g --depth=0 --json": CommandResult(stdout: pnpmListJSON, stderr: "", status: 0),
        "/fake/pnpm outdated -g --json": CommandResult(stdout: "{}", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["pnpm": "/fake/pnpm"])

    let packages = try scanner.scanPNPM(database: PackageDatabase())
    #expect(packages.first?.binaryPath == bin.appendingPathComponent("my-cli").path)
}

@Test func bunParsingHelpersParseListAndOutdatedTable() {
    let listOutput = """
    /Users/test node_modules (42)
    ├── @openai/codex@0.153.1
    ├── cowsay@1.6.0
    └── prettier@3.9.6
    """
    let parsed = PackageScanner.parseBunList(listOutput)
    #expect(parsed.rootDirectory == "/Users/test")
    #expect(parsed.packages.count == 3)
    #expect(parsed.packages[0] == ("@openai/codex", "0.153.1"))
    #expect(parsed.packages[1] == ("cowsay", "1.6.0"))
    #expect(parsed.packages[2] == ("prettier", "3.9.6"))

    let outdatedOutput = """
    bun outdated v1.4.0 (1381054db)
    |--------------------------------------|
    | Package       | Current | Update | Latest |
    |---------------|---------|--------|--------|
    | prettier      | 3.0.0   | 3.0.0  | 3.9.6  |
    | @openai/codex | 0.146.0 | 0.146.0| 0.153.1|
    |--------------------------------------|
    """
    let outdated = PackageScanner.parseBunOutdated(outdatedOutput)
    #expect(outdated["prettier"] == "3.9.6")
    #expect(outdated["@openai/codex"] == "0.153.1")
}

@Test(arguments: ["local-tool", "@scope/cli"])
func bunListPreservesNamesWhenLocalPathsContainAtSigns(_ name: String) throws {
    let path = "../../../../../tmp/tools/@scope/cli"
    let parsed = PackageScanner.parseBunList("└── \(name)@\(path)")
    let package = try #require(parsed.packages.first)
    #expect(package.name == name)
    #expect(package.version == path)
}

@Test func bunScannerUsesGlobalBinOutdatedTableAndPackageBinNames() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let modules = temp.appendingPathComponent("node_modules", isDirectory: true)
    let package = modules.appendingPathComponent("@scope/tool", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try """
    {"name":"@scope/tool","version":"1.0.0","description":"A scoped CLI","homepage":"https://example.com/tool","repository":{"url":"git+https://github.com/example/tool.git"},"bin":{"tool":"cli.js"}}
    """.write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("tool").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/bun pm bin -g": CommandResult(stdout: "\(bin.path)\n", stderr: "", status: 0),
        "/fake/bun pm ls -g --cwd \(FileManager.default.homeDirectoryForCurrentUser.path)": CommandResult(stdout: """
        \(temp.path) node_modules (1)
        └── @scope/tool@1.0.0
        """, stderr: "", status: 0),
        "/fake/bun outdated -g --cwd \(FileManager.default.homeDirectoryForCurrentUser.path)": CommandResult(stdout: """
        | Package | Current | Update | Latest |
        | @scope/tool | 1.0.0 | 1.2.0 | 1.2.0 |
        """, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["bun": "/fake/bun"])

    let packages = try scanner.scanBun(database: PackageDatabase(npms: [
        "@scope/tool": PackageMetadata(summary: "Ignored db summary", category: "developer-tools", homepage: nil, version: "9.9.9")
    ]))

    #expect(packages == [
        ManagedPackage(
            manager: .bun,
            identifier: "bun:@scope/tool",
            displayName: "@scope/tool",
            installedVersion: "1.0.0",
            latestVersion: "1.2.0",
            summary: "A scoped CLI",
            category: "developer-tools",
            homepage: "https://example.com/tool",
            repo: "https://github.com/example/tool",
            installLocation: package.path,
            binaryPath: bin.appendingPathComponent("tool").path
        )
    ])
}

@Test func bunScannerPrefersPackageJSONVersionOverLocalPathInstallVersion() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let modules = temp.appendingPathComponent("node_modules", isDirectory: true)
    let package = modules.appendingPathComponent("local-tool", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try """
    {"name":"local-tool","version":"2.4.1","description":"Local tool installed from path"}
    """.write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/bun pm bin -g": CommandResult(stdout: "\(bin.path)\n", stderr: "", status: 0),
        "/fake/bun pm ls -g --cwd \(FileManager.default.homeDirectoryForCurrentUser.path)": CommandResult(stdout: """
        \(temp.path) node_modules (1)
        └── local-tool@../relative/path/to/local-tool
        """, stderr: "", status: 0),
        "/fake/bun outdated -g --cwd \(FileManager.default.homeDirectoryForCurrentUser.path)": CommandResult(stdout: "", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["bun": "/fake/bun"])

    let packages = try scanner.scanBun(database: PackageDatabase())
    #expect(packages.first?.installedVersion == "2.4.1")
}

@Test func pipxParsingHelpersParseListAndOutdatedOutput() {
    let listJson = """
    {
        "pipx_spec_version": "0.1",
        "venvs": {
            "cowsay": {
                "metadata": {
                    "main_package": {
                        "package": "cowsay",
                        "package_version": "5.0",
                        "apps": ["cowsay"],
                        "app_paths": [
                            {
                                "__Path__": "/Users/test/Library/Application Support/pipx/venvs/cowsay/bin/cowsay",
                                "__type__": "Path"
                            }
                        ]
                    }
                }
            }
        }
    }
    """
    let packages = PackageScanner.parsePipxList(listJson, outdated: ["cowsay": "6.1"])
    #expect(packages.count == 1)
    #expect(packages.first?.displayName == "cowsay")
    #expect(packages.first?.installedVersion == "5.0")
    #expect(packages.first?.latestVersion == "6.1")
    #expect(packages.first?.installLocation == "/Users/test/Library/Application Support/pipx/venvs/cowsay")
    #expect(packages.first?.binaryPath == "/Users/test/Library/Application Support/pipx/venvs/cowsay/bin/cowsay")

    let outdatedJson = """
    {
        "data": {
            "packages": [
                {
                    "package": "cowsay",
                    "latest_version": "6.1",
                    "version": "5.0"
                }
            ]
        }
    }
    """
    let parsedJson = PackageScanner.parsePipxOutdated(outdatedJson)
    #expect(parsedJson["cowsay"] == "6.1")

    let outdatedText = """
    cowsay: 5.0 -> 6.1
    ruff: 0.1.0 -> 0.2.0
    """
    let parsedText = PackageScanner.parsePipxOutdated(outdatedText)
    #expect(parsedText["cowsay"] == "6.1")
    #expect(parsedText["ruff"] == "0.2.0")
}

@Test func pipxScannerUsesVenvAppsAndOutdatedVersions() throws {
    let listJson = """
    {
        "pipx_spec_version": "0.1",
        "venvs": {
            "cowsay": {
                "metadata": {
                    "main_package": {
                        "package": "cowsay",
                        "package_version": "5.0",
                        "apps": ["cowsay"],
                        "app_paths": [
                            {
                                "__Path__": "/fake/venvs/cowsay/bin/cowsay",
                                "__type__": "Path"
                            }
                        ]
                    }
                }
            }
        }
    }
    """
    let outdatedText = "cowsay: 5.0 -> 6.1\n"
    let runner = FakeRunner(responses: [
        "/fake/pipx list --json": CommandResult(stdout: listJson, stderr: "", status: 0),
        "/fake/pipx list --outdated --json": CommandResult(stdout: "", stderr: "", status: 1),
        "/fake/pipx list --outdated": CommandResult(stdout: outdatedText, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["pipx": "/fake/pipx"])
    let packages = try scanner.scanPipx(database: PackageDatabase())

    #expect(packages == [
        ManagedPackage(
            manager: .pipx,
            identifier: "pipx:cowsay",
            displayName: "cowsay",
            installedVersion: "5.0",
            latestVersion: "6.1",
            summary: "Python application installed with pipx",
            category: "developer-tools",
            installLocation: "/fake/venvs/cowsay",
            binaryPath: "/fake/venvs/cowsay/bin/cowsay"
        )
    ])
}

@Test func pipxListRetainsVenvKeyForSuffixedEnvironments() {
    let listJson = """
    {
        "pipx_spec_version": "0.1",
        "venvs": {
            "cowsay_x": {
                "metadata": {
                    "main_package": {
                        "package": "cowsay",
                        "package_version": "5.0",
                        "apps": ["cowsay_x"],
                        "app_paths": [
                            {
                                "__Path__": "/Users/test/Library/Application Support/pipx/venvs/cowsay_x/bin/cowsay_x",
                                "__type__": "Path"
                            }
                        ]
                    }
                }
            }
        }
    }
    """
    let db = PackageDatabase(pipxs: [
        "cowsay": PackageMetadata(summary: "Configurable talking cow", category: "entertainment", homepage: nil, version: "5.0")
    ])

    let packages = PackageScanner.parsePipxList(listJson, outdated: ["cowsay_x": "6.1"], database: db)
    #expect(packages.count == 1)
    let package = packages[0]
    #expect(package.identifier == "pipx:cowsay_x")
    #expect(package.catalogIdentifier == "pipx:cowsay")
    #expect(package.displayName == "cowsay_x")
    #expect(package.packageToken == "cowsay_x")
    #expect(package.installedVersion == "5.0")
    #expect(package.latestVersion == "6.1")
    #expect(package.summary == "Configurable talking cow")
    #expect(package.category == "entertainment")
    #expect(package.binaryPath == "/Users/test/Library/Application Support/pipx/venvs/cowsay_x/bin/cowsay_x")

    // Outdated lookup falls back to package name if venv name is not present
    let fallbackOutdated = PackageScanner.parsePipxList(listJson, outdated: ["cowsay": "6.2"])
    #expect(fallbackOutdated.first?.latestVersion == "6.2")
}

@Test func pipxSuffixedEnvironmentMatchesOutdatedNormalizationAndPreservesCanonicalName() throws {
    let listJson = """
    {
        "pipx_spec_version": "0.1",
        "venvs": {
            "cowsay-x": {
                "metadata": {
                    "injected_packages": {},
                    "main_package": {
                        "app_paths": [
                            {
                                "__Path__": "/Users/test/.local/share/pipx/venvs/cowsay-x/bin/cowsay_x",
                                "__type__": "Path"
                            }
                        ],
                        "apps": [
                            "cowsay_x"
                        ],
                        "include_apps": true,
                        "include_dependencies": false,
                        "man_pages": [],
                        "man_paths": [],
                        "package": "cowsay",
                        "package_or_url": "cowsay==5.0",
                        "package_version": "5.0",
                        "pip_args": [],
                        "suffix": "_x"
                    },
                    "pipx_metadata_version": "0.2",
                    "python_version": "Python 3.12.0",
                    "venv_args": []
                }
            }
        }
    }
    """

    let outdatedJson = """
    {
        "pipx_spec_version": "0.1",
        "data": {
            "packages": [
                {
                    "package": "cowsay_x",
                    "latest_version": "6.1"
                }
            ]
        }
    }
    """

    let outdatedText = """
    cowsay_x: 5.0 -> 6.1
    """

    let parsedOutdatedJson = PackageScanner.parsePipxOutdated(outdatedJson)
    #expect(parsedOutdatedJson == ["cowsay_x": "6.1"])

    let parsedOutdatedText = PackageScanner.parsePipxOutdated(outdatedText)
    #expect(parsedOutdatedText == ["cowsay_x": "6.1"])

    let db = PackageDatabase(pipxs: [
        "cowsay": PackageMetadata(summary: "Configurable talking cow", category: "entertainment", homepage: nil, version: "5.0")
    ])

    // Test with JSON outdated output
    let packagesFromJson = PackageScanner.parsePipxList(listJson, outdated: parsedOutdatedJson, database: db)
    #expect(packagesFromJson.count == 1)
    let packageFromJson = packagesFromJson[0]
    #expect(packageFromJson.identifier == "pipx:cowsay-x")
    #expect(packageFromJson.catalogIdentifier == "pipx:cowsay")
    #expect(packageFromJson.packageToken == "cowsay-x")
    #expect(packageFromJson.displayName == "cowsay-x")
    #expect(packageFromJson.installedVersion == "5.0")
    #expect(packageFromJson.latestVersion == "6.1")
    #expect(packageFromJson.isOutdated == true)
    #expect(packageFromJson.summary == "Configurable talking cow")
    #expect(packageFromJson.category == "entertainment")
    #expect(packageFromJson.binaryPath == "/Users/test/.local/share/pipx/venvs/cowsay-x/bin/cowsay_x")

    // Test with text outdated output
    let packagesFromText = PackageScanner.parsePipxList(listJson, outdated: parsedOutdatedText, database: db)
    #expect(packagesFromText.first?.latestVersion == "6.1")

    // Test fallback when outdated names venv directly
    let packagesFromVenvKey = PackageScanner.parsePipxList(listJson, outdated: ["cowsay-x": "6.3"], database: db)
    #expect(packagesFromVenvKey.first?.latestVersion == "6.3")

    // Test fallback when outdated names canonical package
    let packagesFromPackageKey = PackageScanner.parsePipxList(listJson, outdated: ["cowsay": "6.4"], database: db)
    #expect(packagesFromPackageKey.first?.latestVersion == "6.4")
}

@Test func homebrewScannerUsesCachedAPIMetadata() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let formulaCache = temp.appendingPathComponent("api/formula", isDirectory: true)
    let caskCache = temp.appendingPathComponent("api/cask", isDirectory: true)
    try FileManager.default.createDirectory(at: formulaCache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: caskCache, withIntermediateDirectories: true)
    try """
    {"desc":"Distributed revision control system","homepage":"https://git-scm.com/","versions":{"stable":"2.51.0"},"urls":{"head":{"url":"https://github.com/git/git.git"}}}
    """.write(to: formulaCache.appendingPathComponent("git.json"), atomically: true, encoding: .utf8)
    try """
    {"desc":"Code editor","homepage":"https://code.visualstudio.com/","version":"1.102.0"}
    """.write(to: caskCache.appendingPathComponent("visual-studio-code.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [{
            "name": "git",
            "versions": {"stable":"2.51.0"},
            "installed": [{"version":"2.51.0","installed_on_request":true}],
            "linked_keg": "2.51.0"
          }],
          "casks": [{
            "token": "visual-studio-code",
            "version": "1.102.0",
            "installed": "1.102.0"
          }]
        }
        """#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"], environment: ["HOMEBREW_CACHE": temp.path])

    let packages = try scanner.scanHomebrew(database: PackageDatabase(
        formulas: ["git": PackageMetadata(summary: "Ignored db summary", category: "developer-tools", homepage: nil, version: "9.9.9", lastUpdatedAt: "2026-06-26T22:01:54Z", pulseKind: "updated")],
        casks: ["visual-studio-code": PackageMetadata(summary: nil, category: "productivity", homepage: nil, version: nil)]
    ))

    #expect(packages.map(\.identifier) == ["brew:git", "brew:cask:visual-studio-code"])
    #expect(packages.map(\.displayName) == ["git", "visual-studio-code"])
    #expect(packages.first?.latestVersion == "2.51.0")
    #expect(packages.first?.summary == "Distributed revision control system")
    #expect(packages.first?.category == "developer-tools")
    #expect(packages.first?.homepage == "https://git-scm.com/")
    #expect(packages.first?.repo == "https://github.com/git/git")
    #expect(packages.first?.lastUpdatedAt == "2026-06-26T22:01:54Z")
    #expect(packages.first?.pulseKind == "updated")
    #expect(packages.last?.latestVersion == "1.102.0")
    #expect(packages.last?.summary == "Code editor")
    #expect(packages.last?.category == "productivity")
}

@Test func homebrewScannerUsesOnlyConsolidatedCommandsWithoutAutoUpdate() throws {
    let runner = RecordingRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew --prefix": CommandResult(stdout: "/fake/homebrew\n", stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
    ])

    _ = try PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])
        .scanHomebrew(database: PackageDatabase())

    #expect(runner.calls.map(\.command) == [
        "/fake/brew outdated --json=v2",
        "/fake/brew --prefix",
        "/fake/brew info --json=v2 --installed",
    ])
    #expect(runner.calls.allSatisfy { $0.options.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1" })
}

@Test func homebrewScannerPrefersDatabaseRepositoryOverFormulaSource() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let formulaCache = temp.appendingPathComponent("api/formula", isDirectory: true)
    try FileManager.default.createDirectory(at: formulaCache, withIntermediateDirectories: true)
    try """
    {"desc":"Fast, disk space efficient package manager","homepage":"https://pnpm.io/","versions":{"stable":"11.8.0"},"urls":{"stable":{"url":"https://registry.npmjs.org/pnpm/-/pnpm-11.8.0.tgz"}}}
    """.write(to: formulaCache.appendingPathComponent("pnpm.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[{"name":"pnpm","versions":{"stable":"11.8.0"},"installed":[{"version":"11.8.0","installed_on_request":true}],"linked_keg":"11.8.0"}],"casks":[]}"#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"], environment: ["HOMEBREW_CACHE": temp.path])

    let packages = try scanner.scanHomebrew(database: PackageDatabase(
        formulas: ["pnpm": PackageMetadata(summary: nil, category: "developer-tools", homepage: nil, repo: "https://github.com/pnpm/pnpm", version: nil)]
    ))

    #expect(packages.first?.repo == "https://github.com/pnpm/pnpm")
}

@Test func homebrewScannerUsesInstalledInfoMetadataWhenCacheIsMissing() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/brew --prefix": CommandResult(stdout: "/fake/homebrew\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [{
            "name": "create-dmg",
            "full_name": "create-dmg",
            "desc": "Shell script to build fancy DMGs",
            "homepage": "https://github.com/create-dmg/create-dmg",
            "versions": { "stable": "1.3.0" },
            "installed": [{"version":"1.3.0","installed_on_request":true}],
            "linked_keg": "1.3.0",
            "urls": { "stable": { "url": "https://github.com/create-dmg/create-dmg/archive/refs/tags/v1.3.0.tar.gz" } }
          }],
          "casks": []
        }
        """#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"], environment: ["HOMEBREW_CACHE": temp.path])

    let packages = try scanner.scanHomebrew(database: PackageDatabase(
        formulas: ["create-dmg": PackageMetadata(summary: nil, category: "developer-tools", homepage: nil, version: nil)]
    ))

    #expect(packages.first?.identifier == "brew:create-dmg")
    #expect(packages.first?.summary == "Shell script to build fancy DMGs")
    #expect(packages.first?.latestVersion == "1.3.0")
    #expect(packages.first?.homepage == "https://github.com/create-dmg/create-dmg")
    #expect(packages.first?.repo == "https://github.com/create-dmg/create-dmg")
    #expect(packages.first?.category == "developer-tools")
    #expect(packages.first?.installLocation == "/fake/homebrew/opt/create-dmg")
    #expect(packages.first?.binaryPath == nil)
}

@Test func homebrewScannerRecordsFormulaExecutableNames() throws {
    let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = prefix.appendingPathComponent("bin", isDirectory: true)
    let cellarBin = prefix.appendingPathComponent("Cellar/findutils/4.10.0/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cellarBin, withIntermediateDirectories: true)
    for name in ["gbase32", "gfind"] {
        let target = cellarBin.appendingPathComponent(name)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(name), withDestinationURL: target)
    }
    defer { try? FileManager.default.removeItem(at: prefix) }

    let runner = FakeRunner(responses: [
        "/fake/brew --prefix": CommandResult(stdout: "\(prefix.path)\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[{"name":"findutils","versions":{"stable":"4.10.0"},"installed":[{"version":"4.10.0","installed_on_request":true}],"linked_keg":"4.10.0"}],"casks":[]}"#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.identifier == "brew:findutils")
    #expect(package.binaryPath == cellarBin.appendingPathComponent("gbase32").path)
    #expect(package.executableNames == ["gbase32", "gfind"])
}

@Test func homebrewScannerUsesCaskLocationMetadata() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew --prefix": CommandResult(stdout: "/fake/homebrew\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [],
          "casks": [{
            "token": "codex",
            "desc": "OpenAI's coding agent",
            "homepage": "https://github.com/openai/codex",
            "version": "0.142.5",
            "installed": "0.142.5",
            "artifacts": [{ "binary": ["codex-aarch64-apple-darwin", { "target": "codex" }], "target": "/fake/homebrew/bin/codex" }]
          }]
        }
        """#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.identifier == "brew:cask:codex")
    #expect(package.installLocation == "/fake/homebrew/Caskroom/codex/0.142.5")
    #expect(package.binaryPath == "/fake/homebrew/bin/codex")
    #expect(package.appProvenance == nil)
}

@Test func homebrewScannerMarksCasksWithAppArtifacts() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [],
          "casks": [{
            "token": "visual-studio-code",
            "version": "1.102.0",
            "installed": "1.102.0",
            "artifacts": [{ "app": ["Visual Studio Code.app"] }]
          }]
        }
        """#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.appProvenance == .homebrew)
}

@Test func homebrewScannerDoesNotMarkInstalledFormulaRevisionsOutdated() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [{
            "name": "zopfli",
            "desc": "Compression tool",
            "homepage": "https://github.com/google/zopfli",
            "versions": { "stable": "1.0.3" },
            "installed": [{"version":"1.0.3_1","installed_on_request":true}],
            "linked_keg": "1.0.3_1"
          }],
          "casks": []
        }
        """#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.latestVersion == "1.0.3_1")
    #expect(!package.isOutdated)
}

@Test func homebrewScannerKeepsOnlyRequestedFormulaeAndCasks() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [
            {"name":"git","installed":[{"version":"2.50.0","installed_on_request":true}],"linked_keg":"2.50.0"},
            {"name":"openssl@3","installed":[{"version":"3.5.0","installed_on_request":false}],"linked_keg":"3.5.0"}
          ],
          "casks": [{
            "token": "visual-studio-code",
            "version": "1.101.2",
            "installed": "1.101.2"
          }]
        }
        """#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let packages = try scanner.scanHomebrew(database: PackageDatabase())

    #expect(packages.map(\.identifier) == ["brew:git", "brew:cask:visual-studio-code"])
    #expect(packages.map(\.displayName) == ["git", "visual-studio-code"])
}

@Test func homebrewScannerKeepsTappedRequestedFormulae() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[{"name":"automic-vault/isotopes/gh-cli","installed_versions":["2.94.0"],"current_version":"2.96.0"}],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[{"name":"gh-cli","full_name":"automic-vault/isotopes/gh-cli","installed":[{"version":"2.94.0","installed_on_request":true}],"linked_keg":"2.94.0"}],"casks":[]}"#, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let packages = try scanner.scanHomebrew(database: PackageDatabase())

    #expect(packages.map(\.identifier) == ["brew:gh-cli"])
    #expect(packages.first?.displayName == "gh-cli")
    #expect(packages.first?.latestVersion == "2.96.0")
}

@Test func npxScannerShowsNewestPackageVersionAndKeepsOtherVersions() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    for (cacheID, version) in ["a": "1.0.0", "b": "1.2.0", "c": "1.2.0"] {
        let package = home.appendingPathComponent(".npm/_npx/\(cacheID)/node_modules/acorn", isDirectory: true)
        let transitive = home.appendingPathComponent(".npm/_npx/\(cacheID)/node_modules/commander", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transitive, withIntermediateDirectories: true)
        try #"{"packages":{"":{"dependencies":{"acorn":"\#(version)"}}}}"#
            .write(to: home.appendingPathComponent(".npm/_npx/\(cacheID)/package-lock.json"), atomically: true, encoding: .utf8)
        try #"{"name":"acorn","version":"\#(version)","description":"JS parser","homepage":"https://example.com/acorn","repository":"git+https://github.com/acornjs/acorn.git"}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try #"{"name":"commander","version":"14.0.0"}"#
            .write(to: transitive.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }

    let scanner = PackageScanner(runner: FakeRunner(responses: [:]), homeDirectory: home)
    let packages = try scanner.scanNPX(database: PackageDatabase(npms: [
        "acorn": PackageMetadata(summary: nil, category: "developer-tools", homepage: nil, version: "9.9.9")
    ]))

    #expect(packages.count == 1)
    #expect(packages.first?.isOutdated == false)
    #expect(packages.first?.identifier == "npx:acorn")
    #expect(packages.first?.displayName == "acorn")
    #expect(packages.first?.installedVersion == "1.2.0")
    #expect(packages.first?.installedVersions == ["1.2.0", "1.0.0"])
    #expect(packages.first?.otherInstalledVersions == ["1.0.0"])
    #expect(packages.first?.summary == "JS parser")
    #expect(packages.first?.category == "developer-tools")
    #expect(packages.first?.homepage == "https://example.com/acorn")
    #expect(packages.first?.repo == "https://github.com/acornjs/acorn")
}

@Test func skillsScannerPrefersInstalledExecutableAndScansOnlyGlobalScope() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let lock = home.appendingPathComponent(".agents/.skill-lock.json")
    try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"version":3,"skills":{"global-skill":{"source":"example/tools","sourceType":"github","sourceUrl":"https://github.com/example/tools.git"}}}"#
        .write(to: lock, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: home) }
    let runner = RecordingRunner(responses: [
        "/fake/skills list --global": CommandResult(stdout: """
          \u{001B}[36mglobal-skill\u{001B}[0m  ~/.agents/skills/global-skill  \u{001B}[38;5;102mAgents:\u{001B}[0m Codex
          manual-skill  ~/.codex/skills/manual-skill  Agents: Codex
        """, stderr: "", status: 0)
    ])
    let scanner = PackageScanner(
        runner: runner,
        homeDirectory: home,
        toolPaths: ["skills": "/fake/skills", "npx": "/fake/npx"]
    )

    let packages = try scanner.scanSkills(database: PackageDatabase())

    #expect(runner.calls.map(\.command) == ["/fake/skills list --global"])
    #expect(packages.map(\.identifier) == ["skills:global:global-skill", "skills:global:manual-skill"])
    #expect(packages.map(\.installLocation) == [
        home.appendingPathComponent(".agents/skills/global-skill").path,
        home.appendingPathComponent(".codex/skills/manual-skill").path,
    ])
    #expect(packages.map(\.repo) == ["https://github.com/example/tools", nil])
}

@Test func skillsScannerFallsBackToNPX() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let runner = RecordingRunner(responses: [
        "/fake/npx --yes skills list --global": CommandResult(stdout: "example  /tmp/example  Agents: Codex\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, homeDirectory: home, toolPaths: ["npx": "/fake/npx"])

    let packages = try scanner.scanSkills(database: PackageDatabase())

    #expect(runner.calls.map(\.command) == ["/fake/npx --yes skills list --global"])
    #expect(packages.map(\.identifier) == ["skills:global:example"])
}

@Test func skillsScannerReadsGlobalSkillDirectoriesWithoutCLI() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let skill = home.appendingPathComponent(".agents/skills/example", isDirectory: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try "---\nname: example\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: home) }

    let scanner = PackageScanner(runner: FakeRunner(responses: [:]), homeDirectory: home, environment: [:])
    let packages = try scanner.scanSkills(database: PackageDatabase())

    #expect(packages.map(\.identifier) == ["skills:global:example"])
    #expect(packages.first?.installLocation?.hasSuffix("/.agents/skills/example") == true)
}

@Test func npxScannerUsesNPMResolvedLatestVersion() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let package = home.appendingPathComponent(".npm/_npx/a/node_modules/acorn", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try #"{"packages":{"":{"dependencies":{"acorn":"1.0.0"}}}}"#
        .write(to: home.appendingPathComponent(".npm/_npx/a/package-lock.json"), atomically: true, encoding: .utf8)
    try #"{"name":"acorn","version":"1.0.0","description":"Local parser"}"#
        .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: home) }

    NPMRegistryURLProtocol.responses = ["/acorn": Data("""
    {
      "description": "Registry parser",
      "dist-tags": { "latest": "1.2.0" },
      "versions": {
        "1.2.0": { "homepage": "https://example.com/acorn" }
      }
    }
    """.utf8)]
    defer { NPMRegistryURLProtocol.responses = [:] }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NPMRegistryURLProtocol.self]
    let client = NPMRegistryClient(
        session: URLSession(configuration: configuration),
        baseURL: URL(string: "https://registry.example")!
    )
    let scanner = PackageScanner(runner: NPMResolveRunner(version: "1.1.0"), homeDirectory: home, toolPaths: ["npm": "/fake/npm"])
    let packages = try await scanner.scanNPX(database: PackageDatabase(npms: [
        "acorn": PackageMetadata(summary: nil, category: "developer-tools", homepage: nil, version: nil)
    ]), npmRegistryClient: client)

    #expect(packages.first?.latestVersion == "1.1.0")
    #expect(packages.first?.isOutdated == true)
    #expect(packages.first?.summary == "Local parser")
    #expect(packages.first?.category == "developer-tools")
    #expect(packages.first?.homepage == "https://example.com/acorn")
}

@Test func freshManagerScanResolvesNPXLatestVersion() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let package = home.appendingPathComponent(".npm/_npx/a/node_modules/acorn", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try #"{"packages":{"":{"dependencies":{"acorn":"1.0.0"}}}}"#
        .write(to: home.appendingPathComponent(".npm/_npx/a/package-lock.json"), atomically: true, encoding: .utf8)
    try #"{"name":"acorn","version":"1.0.0"}"#
        .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: home) }

    let scanner = PackageScanner(
        runner: NPMResolveRunner(version: "1.1.0"),
        homeDirectory: home,
        toolPaths: ["npm": "/fake/npm"]
    )
    var result: PackageManagerScanResult?
    for await value in scanner.results(for: [.npx], database: PackageDatabase(), mode: .fresh) {
        result = value
    }

    #expect(result?.packages.first?.latestVersion == "1.1.0")
    #expect(result?.packages.first?.isOutdated == true)
}

@Test func npxScannerIgnoresRegistryLatestWhenNPMResolutionFails() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let package = home.appendingPathComponent(".npm/_npx/a/node_modules/acorn", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try #"{"packages":{"":{"dependencies":{"acorn":"1.0.0"}}}}"#
        .write(to: home.appendingPathComponent(".npm/_npx/a/package-lock.json"), atomically: true, encoding: .utf8)
    try #"{"name":"acorn","version":"1.0.0"}"#
        .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: home) }

    EmptyNPMRegistryURLProtocol.responses = ["/acorn": Data("""
    {
      "dist-tags": { "latest": "1.2.0" },
      "versions": {
        "1.2.0": { "homepage": "https://example.com/acorn" }
      }
    }
    """.utf8)]
    defer { EmptyNPMRegistryURLProtocol.responses = [:] }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EmptyNPMRegistryURLProtocol.self]
    let client = NPMRegistryClient(
        session: URLSession(configuration: configuration),
        baseURL: URL(string: "https://registry.example")!
    )
    let scanner = PackageScanner(runner: NPMResolveRunner(version: nil, status: 1), homeDirectory: home, toolPaths: ["npm": "/fake/npm"])
    let packages = try await scanner.scanNPX(database: PackageDatabase(), npmRegistryClient: client)

    #expect(packages.first?.latestVersion == nil)
    #expect(packages.first?.isOutdated == false)
    #expect(packages.first?.homepage == "https://example.com/acorn")
}

@Test func uvScannerIncludesToolsAndOnlyUvManagedPythons() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let tools = temp.appendingPathComponent("tools", isDirectory: true)
    let bin = temp.appendingPathComponent("bin", isDirectory: true)
    let pythonDir = temp.appendingPathComponent("python", isDirectory: true)
    let pythonBin = pythonDir.appendingPathComponent("cpython-3.13.12-macos-aarch64-none/bin", isDirectory: true)
    let oldPythonBin = pythonDir.appendingPathComponent("cpython-3.13.10-macos-aarch64-none/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: tools.appendingPathComponent("ruff", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pythonBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: oldPythonBin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("ruff").path, contents: Data())
    FileManager.default.createFile(atPath: pythonBin.appendingPathComponent("python3.13").path, contents: Data())
    FileManager.default.createFile(atPath: oldPythonBin.appendingPathComponent("python3.13").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: temp) }

    let pythonJSON = """
    [
      {"key":"cpython-3.13.10-macos-aarch64-none","version":"3.13.10","version_parts":{"major":3,"minor":13,"patch":10},"path":"\(oldPythonBin.appendingPathComponent("python3.13").path)","os":"macos","variant":"default","implementation":"cpython","arch":"aarch64","libc":"none"},
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

    #expect(packages.map(\.identifier) == ["uv:tool:ruff", "uv:cpython:3.13"])
    #expect(packages.map(\.displayName) == ["ruff", "uv Managed Python 3.13"])
    #expect(packages.first?.installedVersion == "0.6.9")
    #expect(packages.first?.latestVersion == "0.7.0")
    #expect(packages.first?.installLocation == tools.appendingPathComponent("ruff").path)
    #expect(packages.first?.binaryPath == bin.appendingPathComponent("ruff").path)
    #expect(packages.last?.identifier == "uv:cpython:3.13")
    #expect(packages.last?.displayName == "uv Managed Python 3.13")
    #expect(packages.last?.installedVersion == "3.13.12")
    #expect(packages.last?.installedVersions == ["3.13.12", "3.13.10"])
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
    #expect(packages.first?.identifier == "uvx:ruff")
    #expect(packages.first?.displayName == "ruff")
    #expect(packages.first?.installedVersion == "0.6.9")
    #expect(packages.first?.summary == "uvx cached tool environment")
    #expect(packages.first?.category == "developer-tools")
    #expect(packages.first?.installLocation?.hasSuffix("/environments-v2/ruff-0123456789abcdef") == true)
    #expect(packages.first?.binaryPath?.hasSuffix("/environments-v2/ruff-0123456789abcdef/bin/ruff") == true)
}

@Test func uvxScannerFallsBackToCacheEntryNameWhenDependenciesAreMarkedRequested() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let environment = temp.appendingPathComponent("environments-v2/site-e32b691154c494a3", isDirectory: true)
    let sitePackages = environment.appendingPathComponent("lib/python3.11/site-packages", isDirectory: true)
    let annotatedTypes = sitePackages.appendingPathComponent("annotated_types-0.7.0.dist-info", isDirectory: true)
    let pydantic = sitePackages.appendingPathComponent("pydantic-2.13.4.dist-info", isDirectory: true)
    try FileManager.default.createDirectory(at: annotatedTypes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pydantic, withIntermediateDirectories: true)
    try "".write(to: annotatedTypes.appendingPathComponent("REQUESTED"), atomically: true, encoding: .utf8)
    try "".write(to: pydantic.appendingPathComponent("REQUESTED"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/uv cache dir": CommandResult(stdout: "\(temp.path)\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["uv": "/fake/uv"])

    let package = try #require(scanner.scanUVX(database: PackageDatabase()).first)

    #expect(package.identifier == "uvx:site")
    #expect(package.displayName == "site")
    #expect(package.installedVersion == nil)
    #expect(package.summary == "uvx cached tool environment")
}

@Test func uvxScannerReadsSymlinkedCachedToolMetadata() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let archive = temp.appendingPathComponent("archive-v0/Q3TrjBbVSvYNhiMC", isDirectory: true)
    let environmentEntry = temp.appendingPathComponent("environments-v2/b0305c6237c84604", isDirectory: true)
    let environmentLink = environmentEntry.appendingPathComponent("5341eec7131f3f0c")
    let bin = archive.appendingPathComponent("bin", isDirectory: true)
    let distInfo = archive.appendingPathComponent("lib/python3.13/site-packages/cowsay-6.1.dist-info", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: distInfo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: environmentEntry, withIntermediateDirectories: true)
    try "".write(to: archive.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
    try "".write(to: distInfo.appendingPathComponent("REQUESTED"), atomically: true, encoding: .utf8)
    try """
    Metadata-Version: 2.1
    Name: cowsay
    Version: 6.1
    Summary: The famous cowsay for GNU/Linux is now available for python
    Home-page: https://github.com/VaasuDevanS/cowsay-python
    """.write(to: distInfo.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: bin.appendingPathComponent("cowsay").path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("cowsay").path)
    try FileManager.default.createSymbolicLink(at: environmentLink, withDestinationURL: archive)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/uv cache dir": CommandResult(stdout: "\(temp.path)\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["uv": "/fake/uv"])

    let package = try #require(scanner.scanUVX(database: PackageDatabase()).first)

    #expect(package.manager == .uvx)
    #expect(package.identifier == "uvx:cowsay")
    #expect(package.displayName == "cowsay")
    #expect(package.installedVersion == "6.1")
    #expect(package.summary == "The famous cowsay for GNU/Linux is now available for python")
    #expect(package.homepage == "https://github.com/VaasuDevanS/cowsay-python")
    #expect(package.installLocation?.hasSuffix("/environments-v2/b0305c6237c84604/5341eec7131f3f0c") == true)
    #expect(package.binaryPath?.hasSuffix("/environments-v2/b0305c6237c84604/5341eec7131f3f0c/bin/cowsay") == true)
}

@Test func uvxScannerSkipsAmbiguousHashBuckets() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let environment = temp.appendingPathComponent("environments-v2/758e20266bf5b18e/c948314f11ff49ce", isDirectory: true)
    let sitePackages = environment.appendingPathComponent("lib/python3.11/site-packages", isDirectory: true)
    try FileManager.default.createDirectory(at: sitePackages.appendingPathComponent("idna-3.17.dist-info", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sitePackages.appendingPathComponent("requests-2.34.2.dist-info", isDirectory: true), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/uv cache dir": CommandResult(stdout: "\(temp.path)\n", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["uv": "/fake/uv"])

    #expect(try scanner.scanUVX(database: PackageDatabase()).isEmpty)
}

@Test func pkgxParsingVersionsExtractsMaxSemver() {
    let output = """
    0.9.0
    1.0.0
    1.1.0
    2.0.0-rc1
    2.0.0
    1.9.9
    """
    #expect(PackageScanner.parsePkgxVersions(output) == "2.0.0")
    #expect(PackageScanner.parsePkgxVersions("") == nil)
    #expect(PackageScanner.parsePkgxVersions("invalid\nnot-a-version") == nil)

    let prereleases = """
    1.0.0-alpha
    1.0.0-alpha.1
    1.0.0-alpha.beta
    1.0.0-beta
    1.0.0-beta.2
    1.0.0-beta.11
    1.0.0-rc.1
    """
    #expect(PackageScanner.parsePkgxVersions(prereleases) == "1.0.0-rc.1")
}

@Test func pkgxScannerReturnsEmptyWhenToolMissing() throws {
    let scanner = PackageScanner(toolPaths: ["pkgx": ""])
    #expect(try scanner.scanPkgx(database: PackageDatabase()).isEmpty)
}

@Test func pkgxScannerParsesPackagesAndBinaries() throws {
    let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
    let gumV2Bin = temp.appendingPathComponent("charm.sh/gum/v2.0.0/bin", isDirectory: true)
    let gumV1 = temp.appendingPathComponent("charm.sh/gum/v1.0.0", isDirectory: true)
    let gumSymlink = temp.appendingPathComponent("charm.sh/gum/v*", isDirectory: false)
    let denoBin = temp.appendingPathComponent("deno.land/v1.39.4/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: gumV2Bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gumV1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: denoBin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: gumSymlink, withDestinationURL: temp.appendingPathComponent("charm.sh/gum/v2.0.0"))

    let gumBinary = gumV2Bin.appendingPathComponent("gum")
    FileManager.default.createFile(atPath: gumBinary.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gumBinary.path)

    let nonExecFile = gumV2Bin.appendingPathComponent("README.txt")
    FileManager.default.createFile(atPath: nonExecFile.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecFile.path)

    let denoBinary = denoBin.appendingPathComponent("deno")
    FileManager.default.createFile(atPath: denoBinary.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denoBinary.path)
    defer { try? FileManager.default.removeItem(at: temp) }

    let scanner = PackageScanner(toolPaths: ["pkgx": "/fake/pkgx"], environment: ["PKGX_DIR": temp.path])
    let packages = try scanner.scanPkgx(database: PackageDatabase())

    #expect(packages.count == 2)
    let gum = packages.first(where: { $0.identifier == "pkgx:charm.sh/gum" })
    #expect(gum?.manager == .pkgx)
    #expect(gum?.displayName == "gum")
    #expect(gum?.installedVersions.sorted() == ["1.0.0", "2.0.0"])
    #expect(gum?.installedVersion == "2.0.0")
    #expect(gum?.executableNames == ["gum"])
    #expect(gum?.binaryPath?.hasSuffix("/charm.sh/gum/v2.0.0/bin/gum") == true)
    #expect(gum?.homepage == "https://pkgx.dev/pkgs/charm.sh/gum/")
    #expect(gum?.docs == "https://docs.pkgx.sh")

    let deno = packages.first(where: { $0.identifier == "pkgx:deno.land" })
    #expect(deno?.manager == .pkgx)
    #expect(deno?.displayName == "deno")
    #expect(deno?.installedVersion == "1.39.4")
    #expect(deno?.executableNames == ["deno"])
    #expect(deno?.binaryPath?.hasSuffix("/deno.land/v1.39.4/bin/deno") == true)
}

@Test func pkgxScannerQueriesFreshnessWhenModeIsFresh() throws {
    let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
    let gumV2Bin = temp.appendingPathComponent("charm.sh/gum/v2.0.0/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: gumV2Bin, withIntermediateDirectories: true)
    let gumBinary = gumV2Bin.appendingPathComponent("gum")
    FileManager.default.createFile(atPath: gumBinary.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gumBinary.path)
    defer { try? FileManager.default.removeItem(at: temp) }

    let platform = PackageScanner.currentPkgxPlatform()
    let runner = FakeRunner(responses: [
        "/fake/curl -fsSL --connect-timeout 2 --max-time 5 https://dist.pkgx.dev/charm.sh/gum/\(platform)/versions.txt": CommandResult(
            stdout: "2.0.0\n2.1.0\n",
            stderr: "",
            status: 0
        ),
        "/fake/curl -fsSL --connect-timeout 2 --max-time 5 https://dist.pkgx.dev/charm.sh/gum/versions.txt": CommandResult(
            stdout: "2.0.0\n2.0.5\n",
            stderr: "",
            status: 0
        )
    ])
    let scanner = PackageScanner(
        runner: runner,
        toolPaths: ["pkgx": "/fake/pkgx", "curl": "/fake/curl"],
        environment: ["PKGX_DIR": temp.path]
    )
    let packages = try scanner.scanPkgx(database: PackageDatabase(), mode: .fresh)
    let gum = packages.first(where: { $0.identifier == "pkgx:charm.sh/gum" })
    #expect(gum?.installedVersion == "2.0.0")
    #expect(gum?.latestVersion == "2.1.0")
    #expect(gum?.isOutdated == true)
}
