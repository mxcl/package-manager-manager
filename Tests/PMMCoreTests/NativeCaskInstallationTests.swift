import CryptoKit
import Foundation
import Testing
@testable import PMMCore

/// Only signature decisions are simulated. Archive mounting, extraction, copying and trashing use macOS.
private final class CaskTestRunner: CommandRunning, @unchecked Sendable {
    var rejectSignature = false
    var homebrewOwnsApp = false
    var team = "EXAMPLETEAM"
    var isRunning = false
    var denyAuthorization = false
    var authorizationRequests = 0

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    func run(_ executable: String, _ arguments: [String], options: CommandRunOptions,
             onOutput: (@Sendable (String) -> Void)?) throws -> CommandResult {
        #expect(!Thread.isMainThread)
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "osascript":
            authorizationRequests += 1
            if denyAuthorization { return CommandResult(stdout: "", stderr: "User canceled.", status: 1) }
            let tool = arguments[2]
            let paths = Array(arguments.dropFirst(3))
            // Simulate authorization only inside the fixture; never request real administrator access in tests.
            let protectedPath = tool == "/bin/mv" ? paths[0] : paths.last!
            let attributes = try FileManager.default.attributesOfItem(atPath: protectedPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedPath)
            if tool == "/bin/rm", let entries = FileManager.default.enumerator(atPath: protectedPath) {
                for case let path as String in entries {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                        ofItemAtPath: URL(fileURLWithPath: protectedPath).appendingPathComponent(path).path)
                }
            }
            let result = try SystemCommandRunner().run(tool, paths)
            if tool == "/bin/mv", result.status == 0 {
                try FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions]!], ofItemAtPath: paths[1])
            }
            return result
        case "codesign", "spctl":
            return CommandResult(stdout: "", stderr: "TeamIdentifier=\(team)\n", status: rejectSignature ? 1 : 0)
        case "brew":
            let json = homebrewOwnsApp ? #"{"casks":[{"token":"example"}]}"# : #"{"casks":[]}"#
            return CommandResult(stdout: json, stderr: "", status: 0)
        default:
            let result = try SystemCommandRunner().run(executable, arguments, options: options, onOutput: onOutput)
            return result
        }
    }
}

private struct CaskFixture {
    let root: URL
    let apps: URL
    let state: URL
    let preferences: PackagePreferencesStore
    let runner = CaskTestRunner()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pmm-native-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        apps = root.appendingPathComponent("Applications")
        state = root.appendingPathComponent("state")
        preferences = PackagePreferencesStore(url: state.appendingPathComponent("preferences.json"))
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    var manager: NativeCaskManager {
        NativeCaskManager(runner: runner, directory: state, preferences: preferences, applicationDirectories: [apps], isAppRunning: { [runner] _ in runner.isRunning })
    }

    func app(version: String, in directory: URL) throws -> URL {
        let app = directory.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.native-test", "CFBundleShortVersionString": version,
                    "CFBundleVersion": version, "CFBundleExecutable": "Example", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("example-binary")
        if !FileManager.default.fileExists(atPath: executable.path) {
            let source = root.appendingPathComponent("example.c")
            try "int main(void) { return 0; }".write(to: source, atomically: true, encoding: .utf8)
            let result = try SystemCommandRunner().run("/usr/bin/clang", ["-arch", NativeCaskRecipe.isAppleSilicon ? "arm64" : "x86_64",
                source.path, "-o", executable.path])
            #expect(result.status == 0)
        }
        try FileManager.default.copyItem(at: executable, to: binaries.appendingPathComponent("Example"))
        return app
    }

    func archive(version: String, dmg: Bool = false) throws -> (URL, NativeCaskRecipe, URL) {
        let work = root.appendingPathComponent(UUID().uuidString)
        let source = work.appendingPathComponent("source")
        let app = try app(version: version, in: source)
        let archive = work.appendingPathComponent(dmg ? "download.dmg" : "download.zip")
        let command: (String, [String]) = dmg
            ? ("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-format", "UDZO", archive.path])
            : ("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let result = try SystemCommandRunner().run(command.0, command.1)
        #expect(result.status == 0)
        let data = try Data(contentsOf: archive)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let recipe = NativeCaskRecipe(token: "example", version: version, url: URL(string: "https://example.com/download")!,
            sha256: hash, app: "Example.app", targetName: "Example.app", conflicts: [], quitBundleIdentifiers: [])
        return (archive, recipe, work)
    }

    func install(version: String, previous: NativeCaskInstallation? = nil, dmg: Bool = false) throws -> NativeCaskInstallation {
        let (archive, recipe, work) = try archive(version: version, dmg: dmg)
        try NativeCaskManager.verifyChecksum(archive, expected: recipe.sha256)
        try manager.installArchive(archive, work: work, recipe: recipe, previous: previous, onProgress: nil)
        return try #require(NativeCaskStore(directory: state).load()["example"])
    }

    func package(_ receipt: NativeCaskInstallation) -> ManagedPackage {
        ManagedPackage(manager: .macApp, identifier: "mac-app:\(receipt.bundleIdentifier)", catalogIdentifier: "brew:cask:example",
            installedVersion: receipt.version, latestVersion: "3.0", installLocation: receipt.appPath,
            bundleIdentifier: receipt.bundleIdentifier, appProvenance: .direct, nativeCaskInstallation: receipt)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func nativeZIPInstallUpdateAndUninstallPreserveData() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    try await nativeCaskWork {
        let first = try fixture.install(version: "1.0")
        #expect(FileManager.default.fileExists(atPath: first.appPath))
        let second = try fixture.install(version: "2.0", previous: first)
        #expect(second.version == "2.0")
        #expect(try fixture.manager.installations()["example"] == second)
        let userData = fixture.root.appendingPathComponent("application-data")
        try Data("keep me".utf8).write(to: userData)
        try fixture.manager.uninstall(fixture.package(second))
        #expect(!FileManager.default.fileExists(atPath: second.appPath))
        #expect(try NativeCaskStore(directory: fixture.state).load().isEmpty)
        #expect(try String(contentsOf: userData, encoding: .utf8) == "keep me")
    }
}

@Test(arguments: [false, true])
func nativeUpdateRequestsAuthorizationForProtectedApp(denied: Bool) async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    try await nativeCaskWork {
        let first = try fixture.install(version: "1.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: first.appPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: first.appPath) }
        fixture.runner.denyAuthorization = denied
        if denied {
            #expect(throws: NativeCaskError.self) { try fixture.install(version: "2.0", previous: first) }
            #expect(try fixture.manager.installations()["example"] == first)
        } else {
            let updated = try fixture.install(version: "2.0", previous: first)
            #expect(updated.version == "2.0")
        }
        #expect(fixture.runner.authorizationRequests == (denied ? 1 : 2))
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: first.appPath).appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: String]
        #expect(info?["CFBundleShortVersionString"] == (denied ? "1.0" : "2.0"))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("native-cask-transaction.json").path))
    }
}

@Test func nativeDMGInstallMountsAndDetaches() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    try await nativeCaskWork {
        let receipt = try fixture.install(version: "1.0", dmg: true)
        #expect(receipt.shortVersion == "1.0")
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("native-cask-transaction.json").path))
    }
}

@Test func nativeInstallRefusesCollisionSignatureChangeAndDisabledSetting() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    await #expect(throws: NativeCaskError.self) {
        try await nativeCaskWork { try fixture.install(version: "1.0") }
    }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    try await nativeCaskWork {
        let first = try fixture.install(version: "1.0")
        #expect(throws: NativeCaskError.self) { try fixture.install(version: "2.0") }
        fixture.runner.isRunning = true
        #expect(throws: NativeCaskError.self) { try fixture.install(version: "2.0", previous: first) }
        #expect(throws: NativeCaskError.self) { try fixture.manager.uninstall(fixture.package(first)) }
        fixture.runner.isRunning = false
        fixture.runner.team = "DIFFERENTTEAM"
        #expect(throws: NativeCaskError.self) { try fixture.install(version: "2.0", previous: first) }
        #expect(try NativeCaskStore(directory: fixture.state).load()["example"] == first)
        fixture.runner.team = "EXAMPLETEAM"
        fixture.runner.rejectSignature = true
        #expect(throws: NativeCaskError.self) { try fixture.install(version: "2.0", previous: first) }
        #expect(FileManager.default.fileExists(atPath: first.appPath))
    }
}

@Test func nativeAdoptionRequiresUnambiguousDirectApp() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    try await nativeCaskWork {
        let app = try fixture.app(version: "1.0", in: fixture.apps)
        let recipe = NativeCaskRecipe(token: "example", version: "2.0", url: URL(string: "https://example.com/app.zip")!,
            sha256: String(repeating: "0", count: 64), app: "Example.app", targetName: "Example.app", conflicts: [], quitBundleIdentifiers: [])
        let package = ManagedPackage(manager: .macApp, identifier: "mac-app:com.example.native-test", catalogIdentifier: "brew:cask:example",
            installedVersion: "1.0", latestVersion: "2.0", installLocation: app.path, bundleIdentifier: "com.example.native-test", appProvenance: .direct)
        let database = PackageDatabase(apps: ["com.example.native-test": MacAppCatalogEntry(bundleIdentifier: "com.example.native-test", cask: "example")])
        #expect(throws: NativeCaskError.self) {
            try fixture.manager.adopt(package, recipe: recipe, inventory: PackageInventory(packages: [package, package]), database: database)
        }
        try fixture.manager.adopt(package, recipe: recipe, inventory: PackageInventory(packages: [package]), database: database)
        let receipt = try #require(NativeCaskStore(directory: fixture.state).load()["example"])
        #expect(receipt.version == "1.0")
        #expect(receipt.appPath == app.path)
        #expect(throws: NativeCaskError.self) {
            try fixture.manager.adopt(package, recipe: recipe, inventory: PackageInventory(packages: [package]), database: database)
        }
    }
}

@Test func nativeRecoveryRollsBackUncommittedReplacement() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    try await nativeCaskWork {
        let old = try fixture.install(version: "1.0")
        let staging = fixture.apps.appendingPathComponent(".pmm-interrupted")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: old.appPath), to: staging.appendingPathComponent("previous.app"))
        _ = try fixture.app(version: "2.0", in: fixture.apps)
        let new = NativeCaskInstallation(token: old.token, version: "2.0", appPath: old.appPath, bundleIdentifier: old.bundleIdentifier,
            teamIdentifier: old.teamIdentifier, shortVersion: "2.0", bundleVersion: "2.0")
        let encoder = JSONEncoder()
        let journal: [String: Any] = ["receipt": try JSONSerialization.jsonObject(with: encoder.encode(new)),
            "previous": try JSONSerialization.jsonObject(with: encoder.encode(old)), "stagingPath": staging.path]
        try JSONSerialization.data(withJSONObject: journal).write(to: fixture.state.appendingPathComponent("native-cask-transaction.json"))
        try fixture.manager.recover()
        #expect(try NativeCaskStore(directory: fixture.state).load()["example"] == old)
        let restored = try Data(contentsOf: URL(fileURLWithPath: old.appPath).appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: restored, format: nil) as? [String: String]
        #expect(info?["CFBundleShortVersionString"] == "1.0")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}

@Test func nativeReceiptsSurviveScanningAndLoseAuthorityWhenIdentityChanges() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    let receipt = try await nativeCaskWork { try fixture.install(version: "1.0") }
    let scanner = MacAppScanner(runner: fixture.runner, fileManager: .default, applicationDirectories: [fixture.apps],
        brew: nil, mdls: "/usr/bin/mdls", session: .shared, cacheURL: fixture.state.appendingPathComponent("versions.json"),
        now: { Date() }, storefrontCountry: "US", nativeManager: fixture.manager)
    #expect(try await nativeCaskWork { fixture.manager.matches(receipt, app: URL(fileURLWithPath: receipt.appPath)) })
    let packages = try await scanner.scan(database: PackageDatabase(), mode: .local)
    #expect(packages.first?.installLocation == receipt.appPath)
    #expect(packages.count == 1)
    #expect(packages.first?.nativeCaskInstallation == receipt)
    #expect(packages.first?.catalogIdentifier == "brew:cask:example")
    #expect(try JSONDecoder().decode(ManagedPackage.self, from: JSONEncoder().encode(packages[0])) == packages[0])
    fixture.runner.team = "DIFFERENTTEAM"
    let changed = try await scanner.scan(database: PackageDatabase(), mode: .local)
    #expect(changed.first?.nativeCaskInstallation == nil)
    #expect(changed.count == 1)
    try await nativeCaskWork {
        try FileManager.default.removeItem(atPath: receipt.appPath)
        #expect(try fixture.manager.installations().isEmpty)
    }
}

@Test func nativeOperationsShareAnExclusiveFilesystemLock() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await nativeCaskWork {
        let first = NativeCaskStore(directory: fixture.state)
        let fd = try first.lock()
        defer { close(fd) }
        #expect(throws: NativeCaskError.self) { try NativeCaskStore(directory: fixture.state).lock() }
    }
}

private final class AutomaticCaskProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json = """
        {"token":"example","tap":"homebrew/cask","version":"1.0","url":"https://example.com/app.zip",
         "sha256":"\(String(repeating: "0", count: 64))","artifacts":[{"app":["Example.app"]}]}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(arguments: [PackageHostActionKind.update, .uninstall])
func nativeActionsAutomaticallyAdoptRecognizedApps(kind: PackageHostActionKind) async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    let app = try await nativeCaskWork { try fixture.app(version: "1.0", in: fixture.apps) }
    let package = ManagedPackage(manager: .macApp, identifier: "mac-app:com.example.native-test", catalogIdentifier: "brew:cask:example",
        installedVersion: "1.0", latestVersion: "2.0", installLocation: app.path, bundleIdentifier: "com.example.native-test", appProvenance: .direct)
    let database = PackageDatabase(apps: ["com.example.native-test": MacAppCatalogEntry(bundleIdentifier: "com.example.native-test", cask: "example", version: "99.0")])
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AutomaticCaskProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let manager = NativeCaskManager(runner: fixture.runner, session: session, directory: fixture.state, preferences: fixture.preferences,
        applicationDirectories: [fixture.apps], homebrewExecutable: { nil }, isAppRunning: { _ in false },
        loadDatabase: { database }, scanApps: { _ in PackageInventory(packages: [package]) })
    await #expect(throws: NativeCaskError.self) { try await manager.perform(kind, package: package) }
    #expect(try NativeCaskStore(directory: fixture.state).load().isEmpty)
    try await fixture.preferences.setNativeCaskManagementEnabled(true)
    let scanner = MacAppScanner(runner: fixture.runner, fileManager: .default, applicationDirectories: [fixture.apps],
        brew: nil, mdls: "/usr/bin/mdls", session: session, cacheURL: fixture.state.appendingPathComponent("versions.json"),
        now: { Date() }, storefrontCountry: "US", nativeManager: manager)
    let discovered = try await scanner.scan(database: database, mode: .fresh)
    #expect(discovered.count == 1)
    #expect(discovered.first?.nativeCaskInstallation == nil)
    #expect(discovered.first?.versionSource == .homebrewCask)
    #expect(discovered.first?.isOutdated == false) // Uses the compatible recipe, not catalog version 99.
    try await manager.perform(kind, package: package)
    if kind == .uninstall {
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(try NativeCaskStore(directory: fixture.state).load().isEmpty)
    } else {
        let receipt = try #require(NativeCaskStore(directory: fixture.state).load()["example"])
        #expect(receipt.appPath == app.path)
        #expect(receipt.bundleIdentifier == package.bundleIdentifier)
        // The API says it is already current; ownership is established without replacing it.
        #expect(receipt.version == "1.0")
    }
}

@Test(arguments: ["success", "signature", "team", "running", "old-version"])
func directAppReplacementPreservesOriginalOnFailure(scenario: String) async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await nativeCaskWork {
        let app = try fixture.app(version: "1.0", in: fixture.apps)
        let previous = NativeCaskInstallation(token: "example", version: "1.0", appPath: app.path,
            bundleIdentifier: "com.example.native-test", teamIdentifier: "EXAMPLETEAM", shortVersion: "1.0", bundleVersion: "1.0")
        let (archive, recipe, work) = try fixture.archive(version: scenario == "old-version" ? "1.0" : "2.0")
        fixture.runner.rejectSignature = scenario == "signature"
        fixture.runner.team = scenario == "team" ? "OTHERTEAM" : "EXAMPLETEAM"
        fixture.runner.isRunning = scenario == "running"
        let install = {
            try fixture.manager.installArchive(archive, work: work, recipe: recipe, previous: previous, direct: true, onProgress: nil)
        }
        if scenario == "success" { try install() }
        else { #expect(throws: NativeCaskError.self) { try install() } }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: String]
        #expect(info?["CFBundleVersion"] == (scenario == "success" ? "2.0" : "1.0"))
        #expect(try NativeCaskStore(directory: fixture.state).load().isEmpty)
    }
}

@Test func updateGuardFindsRunningAppThroughHomebrewSymlink() async throws {
    let fixture = try CaskFixture()
    defer { fixture.clean() }
    try await nativeCaskWork {
        let app = try fixture.app(version: "1.0", in: fixture.apps)
        let caskroom = fixture.root.appendingPathComponent("Caskroom/example/1.0")
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caskroom.appendingPathComponent("Example.app"), withDestinationURL: app)
        let package = ManagedPackage(manager: .homebrew, identifier: "brew:cask:example", displayName: "Example", installedVersion: "1.0", latestVersion: "2.0", installLocation: caskroom.path)
        #expect(throws: NativeCaskError("Quit Example, then try Update again.")) {
            try PackageUpdater.requireAppsClosed(package, isRunning: { $0 == "com.example.native-test" })
        }
        try PackageUpdater.requireAppsClosed(package, isRunning: { _ in false })
    }
}
