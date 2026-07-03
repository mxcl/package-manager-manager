import Foundation
import Testing
@testable import PMMCore

@Test func packageHostSnapshotRoundTripsJSON() throws {
    let package = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let snapshot = PackageHostSnapshot(
        inventory: PackageInventory(generatedAt: Date(timeIntervalSince1970: 10), packages: [package], errors: ["scan warning"]),
        catalogPackages: [package],
        isRefreshing: true,
        runningAction: PackageHostRunningAction(kind: .update, packageID: package.id, displayName: "git"),
        errorMessage: "brew failed",
        lastBrewUpdateAt: Date(timeIntervalSince1970: 20)
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(PackageHostSnapshot.self, from: data)

    #expect(decoded == snapshot)
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
