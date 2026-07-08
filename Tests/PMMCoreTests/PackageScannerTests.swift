import Foundation
import Testing
@testable import PMMCore

private struct FakeRunner: CommandRunning {
    let responses: [String: CommandResult]

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        responses[([executable] + arguments).joined(separator: " ")] ?? CommandResult(stdout: "", stderr: "", status: 0)
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
            summary: "Rust toolchain (active, default)",
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
            summary: "Rust toolchain",
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
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "git\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "git 2.51.0\n", stderr: "", status: 0),
        "/fake/brew info --installed --cask --json=v2": CommandResult(stdout: #"""
        {
          "formulae": [],
          "casks": [{
            "token": "visual-studio-code",
            "version": "1.102.0"
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

@Test func homebrewScannerPrefersDatabaseRepositoryOverFormulaSource() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let formulaCache = temp.appendingPathComponent("api/formula", isDirectory: true)
    try FileManager.default.createDirectory(at: formulaCache, withIntermediateDirectories: true)
    try """
    {"desc":"Fast, disk space efficient package manager","homepage":"https://pnpm.io/","versions":{"stable":"11.8.0"},"urls":{"stable":{"url":"https://registry.npmjs.org/pnpm/-/pnpm-11.8.0.tgz"}}}
    """.write(to: formulaCache.appendingPathComponent("pnpm.json"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runner = FakeRunner(responses: [
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "pnpm\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "pnpm 11.8.0\n", stderr: "", status: 0),
        "/fake/brew list --versions --cask": CommandResult(stdout: "", stderr: "", status: 0),
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
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "create-dmg\n", stderr: "", status: 0),
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
            "urls": { "stable": { "url": "https://github.com/create-dmg/create-dmg/archive/refs/tags/v1.3.0.tar.gz" } }
          }],
          "casks": []
        }
        """#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "create-dmg 1.3.0\n", stderr: "", status: 0),
        "/fake/brew list --versions --cask": CommandResult(stdout: "", stderr: "", status: 0),
        "/fake/brew list --formula create-dmg": CommandResult(stdout: "/fake/homebrew/Cellar/create-dmg/1.3.0/bin/create-dmg\n", stderr: "", status: 0),
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
    #expect(packages.first?.binaryPath == "/fake/homebrew/Cellar/create-dmg/1.3.0/bin/create-dmg")
}

@Test func homebrewScannerRecordsFormulaExecutableNames() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "findutils\n", stderr: "", status: 0),
        "/fake/brew --prefix": CommandResult(stdout: "/fake/homebrew\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "findutils 4.10.0\n", stderr: "", status: 0),
        "/fake/brew list --versions --cask": CommandResult(stdout: "", stderr: "", status: 0),
        "/fake/brew list --formula findutils": CommandResult(stdout: """
        /fake/homebrew/Cellar/findutils/4.10.0/bin/gbase32
        /fake/homebrew/Cellar/findutils/4.10.0/bin/gfind
        """, stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.identifier == "brew:findutils")
    #expect(package.binaryPath == "/fake/homebrew/Cellar/findutils/4.10.0/bin/gbase32")
    #expect(package.executableNames == ["gbase32", "gfind"])
}

@Test func homebrewScannerUsesCaskLocationMetadata() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "", stderr: "", status: 0),
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
        "/fake/brew info --installed --cask --json=v2": CommandResult(stdout: #"""
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
        "/fake/brew list --versions --formula": CommandResult(stdout: "", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.identifier == "brew:cask:codex")
    #expect(package.installLocation == "/fake/homebrew/Caskroom/codex/0.142.5")
    #expect(package.binaryPath == "/fake/homebrew/bin/codex")
}

@Test func homebrewScannerDoesNotMarkInstalledFormulaRevisionsOutdated() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "zopfli\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew info --json=v2 --installed": CommandResult(stdout: #"""
        {
          "formulae": [{
            "name": "zopfli",
            "desc": "Compression tool",
            "homepage": "https://github.com/google/zopfli",
            "versions": { "stable": "1.0.3" },
            "linked_keg": "1.0.3_1"
          }],
          "casks": []
        }
        """#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "zopfli 1.0.3_1\n", stderr: "", status: 0),
        "/fake/brew list --versions --cask": CommandResult(stdout: "", stderr: "", status: 0),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let package = try #require(scanner.scanHomebrew(database: PackageDatabase()).first)

    #expect(package.latestVersion == "1.0.3_1")
    #expect(!package.isOutdated)
}

@Test func homebrewScannerKeepsOnlyRequestedFormulaeAndCasks() throws {
    let runner = FakeRunner(responses: [
        "/fake/brew leaves --installed-on-request": CommandResult(stdout: "git\n", stderr: "", status: 0),
        "/fake/brew outdated --json=v2": CommandResult(stdout: #"{"formulae":[],"casks":[]}"#, stderr: "", status: 0),
        "/fake/brew list --versions --formula": CommandResult(stdout: "git 2.50.0\nopenssl@3 3.5.0\n", stderr: "", status: 0),
        "/fake/brew info --installed --cask --json=v2": CommandResult(stdout: #"""
        {
          "formulae": [],
          "casks": [{
            "token": "visual-studio-code",
            "version": "1.101.2"
          }]
        }
        """#, stderr: "", status: 0),
        "/fake/brew list --versions --cask": CommandResult(stdout: "", stderr: "Error: Cask 'visual-studio-code' is not installed.\n", status: 1),
    ])
    let scanner = PackageScanner(runner: runner, toolPaths: ["brew": "/fake/brew"])

    let packages = try scanner.scanHomebrew(database: PackageDatabase())

    #expect(packages.map(\.identifier) == ["brew:git", "brew:cask:visual-studio-code"])
    #expect(packages.map(\.displayName) == ["git", "visual-studio-code"])
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
