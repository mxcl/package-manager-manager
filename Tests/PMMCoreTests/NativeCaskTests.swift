import CryptoKit
import Foundation
import Testing
@testable import PMMCore

private func caskJSON(_ changes: [String: Any] = [:]) throws -> Data {
    let raw: [String: Any] = [
        "token": "example", "tap": "homebrew/cask", "version": "2.0", "sha256": String(repeating: "a", count: 64),
        "url": "https://example.com/app.zip", "url_specs": [:], "depends_on": ["macos": [">=": ["13"]]],
        "artifacts": [["app": ["Example.app"], "target": "/Applications/Example.app"], ["zap": [["trash": "~/Library/Preferences/example"]]]]
    ]
    return try JSONSerialization.data(withJSONObject: raw.merging(changes) { _, new in new })
}

@Test func nativeRecipesResolveArchitectureAndRejectUnsupportedActions() throws {
    let variants: [String: Any] = ["tahoe": ["url": "https://example.com/intel.zip", "sha256": String(repeating: "b", count: 64)]]
    let data = try caskJSON(["variations": variants])
    let intel = try NativeCaskRecipe.decode(data, token: "example", osMajor: 26, osVersion: "26.0", arm64: false)
    #expect(intel.url.lastPathComponent == "intel.zip")
    #expect(intel.sha256 == String(repeating: "b", count: 64))
    let arm = try NativeCaskRecipe.decode(data, token: "example", osMajor: 26, osVersion: "26.0", arm64: true)
    #expect(arm.url.lastPathComponent == "app.zip")
    for change: [String: Any] in [
        ["sha256": "no_check"], ["version": "latest"], ["disabled": true], ["url": "http://example.com/app.zip"],
        ["depends_on": ["formula": ["node"]]], ["depends_on": ["macos": [">=": ["27"]]]],
        ["depends_on": ["arch": ["x86_64"]]], ["artifacts": [["pkg": ["Example.pkg"]]]],
        ["artifacts": [["app": ["../Example.app"]]]],
        ["artifacts": [["app": ["Example.app"]], ["preflight": "system('sh')"]]],
        ["artifacts": [["app": ["Example.app"]], ["uninstall": [["launchctl": "example"]]]]],
        ["artifacts": [["app": ["One.app"]], ["app": ["Two.app"]]]]
    ] {
        #expect(throws: NativeCaskError.self) {
            try NativeCaskRecipe.decode(caskJSON(change), token: "example", osMajor: 26, osVersion: "26.0", arm64: true)
        }
    }
}

@Test func nativePreferencesDefaultOffAndDismissalsCannotOverwriteToggle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("preferences.json")
    let store = PackagePreferencesStore(url: url)
    #expect(store.load().nativeCaskManagementEnabled == false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"dismissedPrompts":["old"]}"#.utf8).write(to: url)
    #expect(store.load().hasDismissed("old"))
    let stale = store.load()
    try await store.setNativeCaskManagementEnabled(true)
    store.save(stale)
    store.flush()
    #expect(store.load().nativeCaskManagementEnabled)
    try await store.setNativeCaskManagementEnabled(false)
    #expect(!store.load().nativeCaskManagementEnabled)
    #expect(store.load().hasDismissed("old"))
}

@Test func nativePreferencesSurfaceWriteFailure() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = PackagePreferencesStore(url: file.appendingPathComponent("preferences.json"))
    await #expect(throws: (any Error).self) { try await store.setNativeCaskManagementEnabled(true) }
}

@Test func nativeChecksumAndBundleContainment() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("download")
    let data = Data("test download".utf8)
    try data.write(to: file)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try NativeCaskManager.verifyChecksum(file, expected: hash)
    #expect(throws: NativeCaskError.self) { try NativeCaskManager.verifyChecksum(file, expected: String(repeating: "0", count: 64)) }
    let app = directory.appendingPathComponent("Example.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("escape"), withDestinationURL: directory)
    #expect(throws: NativeCaskError.self) { try NativeCaskManager.validateBundlePaths(app) }
}

@Test func nativeVersionsCompareCaskBuildNumbersWithoutDowngrading() {
    #expect(NativeCaskManager.isNewer("2.0,20", than: "2.0,19"))
    #expect(!NativeCaskManager.isNewer("2.0,19", than: "2.0,20"))
    #expect(!NativeCaskManager.isNewer("2.0", than: "3.0"))
}
