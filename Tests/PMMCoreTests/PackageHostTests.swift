import Foundation
import Testing
@testable import PMMCore

@Test func packageHostSnapshotRoundTripsJSON() throws {
    let package = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let snapshot = PackageHostSnapshot(
        inventory: PackageInventory(generatedAt: Date(timeIntervalSince1970: 10), packages: [package], errors: ["scan warning"]),
        catalogPackages: [package],
        isRefreshing: true,
        loadingManagers: [.homebrew],
        runningAction: PackageHostRunningAction(
            kind: .update,
            packageID: package.id,
            displayName: "git",
            command: "brew upgrade git",
            output: "\u{1B}[32mok\u{1B}[0m\n"
        ),
        errorMessage: "brew failed",
        lastBrewUpdateAt: Date(timeIntervalSince1970: 20),
        installedPackageFirstSeenAtByID: [package.id: Date(timeIntervalSince1970: 30)]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(PackageHostSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func packageHostSnapshotDecodesOldJSONWithoutFirstSeenHistory() throws {
    let data = Data("""
    {
      "catalogPackages": [],
      "isRefreshing": false,
      "inventory": { "generatedAt": 0, "packages": [], "errors": [] }
    }
    """.utf8)

    let decoded = try JSONDecoder().decode(PackageHostSnapshot.self, from: data)

    #expect(decoded.installedPackageFirstSeenAtByID == nil)
    #expect(decoded.loadingManagers == nil)
}

@Test func packageHostRunningActionDecodesOldJSONWithoutCommandOutput() throws {
    let data = Data("""
    {
      "kind": "update",
      "packageID": "brew:git",
      "displayName": "git"
    }
    """.utf8)

    let decoded = try JSONDecoder().decode(PackageHostRunningAction.self, from: data)

    #expect(decoded.command == nil)
    #expect(decoded.output == nil)
}

@Test func packageHostSnapshotTracksInstalledPackageFirstSeenDates() {
    let baseline = Date(timeIntervalSince1970: 0)
    let firstScan = Date(timeIntervalSince1970: 100)
    let secondScan = Date(timeIntervalSince1970: 200)
    let existing = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "1")
    let added = ManagedPackage(manager: .npm, name: "typescript", installedVersion: "1", latestVersion: "1")
    var snapshot = PackageHostSnapshot(inventory: PackageInventory(generatedAt: firstScan, packages: [existing]))

    snapshot.updateInstalledPackageFirstSeenAtByID()
    snapshot.inventory = PackageInventory(generatedAt: secondScan, packages: [existing, added])
    snapshot.updateInstalledPackageFirstSeenAtByID()

    #expect(snapshot.installedPackageFirstSeenAtByID?[existing.id] == baseline)
    #expect(snapshot.installedPackageFirstSeenAtByID?[added.id] == secondScan)
}

@Test func packageHostStoreReadsAndWritesSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PackageHostStore(directory: root)
    let snapshot = PackageHostSnapshot(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .npm, name: "typescript", installedVersion: "1", latestVersion: "2")
    ]))

    try store.save(snapshot)

    #expect(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    #expect(try store.load() == snapshot)
}
