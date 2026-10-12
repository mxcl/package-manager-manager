import Foundation
import Testing
@testable import PMMCore

@Test func packageIdentifierDrivesIDAndDisplayNameDefaultsToIdentifier() {
    let package = ManagedPackage(
        manager: .npm,
        identifier: "npm:typescript",
        installedVersion: "5.9.2",
        latestVersion: nil,
        installLocation: "/tmp/typescript"
    )

    #expect(package.id == "npm:typescript:/tmp/typescript")
    #expect(package.name == "npm:typescript")
    #expect(package.displayName == "npm:typescript")
}

@Test func packageDecodesOldJSONNameAndEncodesQualifiedNames() throws {
    let oldJSON = #"{"manager":"npm","name":"typescript","installedVersion":"5.9.2","latestVersion":null}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ManagedPackage.self, from: oldJSON)

    #expect(decoded.identifier == "typescript")
    #expect(decoded.displayName == "typescript")

    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ManagedPackage(
        manager: .npm,
        identifier: "npm:typescript",
        catalogIdentifier: "brew:cask:typescript",
        displayName: "typescript",
        installedVersion: "5.9.2",
        latestVersion: nil
    ))) as? [String: Any]

    #expect(encoded?["identifier"] as? String == "npm:typescript")
    #expect(encoded?["name"] as? String == "npm:typescript")
    #expect(encoded?["displayName"] as? String == "typescript")
    #expect(encoded?["catalogIdentifier"] as? String == "brew:cask:typescript")
}

@Test func packageNormalizesRustupToolchainFieldsFromCachedJSON() throws {
    let data = #"{"manager":"rustup","identifier":"rustup:toolchain:1.92.0-aarch64-apple-darwin","displayName":"1.92.0-aarch64-apple-darwin","installedVersion":"1.92.0","latestVersion":null}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ManagedPackage.self, from: data)

    #expect(decoded.displayName == "rust 1.92.0 ²")
    #expect(decoded.summary == "rustup managed Rust toolchain")
}

@Test func packageConsolidationGroupsByIdentifierAndPreservesDisplayName() {
    let packages = ManagedPackage.consolidatingInstalledVersions(in: [
        ManagedPackage(manager: .uv, identifier: "uv:cpython:3.13", displayName: "uv Managed Python 3.13", installedVersion: "3.13.10", latestVersion: "3.13.14"),
        ManagedPackage(manager: .uv, identifier: "uv:cpython:3.13", displayName: "Different Label", installedVersion: "3.13.12", latestVersion: "3.13.14"),
        ManagedPackage(manager: .uv, identifier: "uv:cpython:3.14", displayName: "uv Managed Python 3.14", installedVersion: "3.14.0", latestVersion: nil),
    ])

    #expect(packages.map(\.identifier) == ["uv:cpython:3.13", "uv:cpython:3.14"])
    #expect(packages.first?.displayName == "Different Label")
    #expect(packages.first?.installedVersions == ["3.13.12", "3.13.10"])
}

@Test func packageWithLatestAmongInstalledVersionsIsNotOutdated() {
    let package = ManagedPackage(
        manager: .npx,
        name: "playwright",
        installedVersion: "1.2.0",
        installedVersions: ["1.0.0", "1.2.0"],
        latestVersion: "1.2.0"
    )

    #expect(package.isOutdated == false)
    #expect(package.otherInstalledVersions == ["1.0.0"])
}

@Test func packageWithoutLatestAmongInstalledVersionsIsOutdated() {
    let package = ManagedPackage(
        manager: .npx,
        name: "playwright",
        installedVersion: "1.2.0",
        installedVersions: ["1.0.0", "1.2.0"],
        latestVersion: "1.3.0"
    )

    #expect(package.isOutdated == true)
}

@Test func singleVersionPackageOutdatedBehaviorIsUnchanged() {
    #expect(ManagedPackage(manager: .npm, name: "old", installedVersion: "1.0.0", latestVersion: "1.1.0").isOutdated)
    #expect(!ManagedPackage(manager: .npm, name: "current", installedVersion: "1.1.0", latestVersion: "1.1.0").isOutdated)
}

@Test func packageVersionLabelsOmitCommaSeparatedMetadata() {
    #expect(packageVersionDisplayText("2.19675.0,5706e5524dba58b23e105c31c358df8ab0a95852") == "2.19675.0")
    #expect(packageVersionDisplayText("1.2.3,456,789") == "1.2.3")
    #expect(packageVersionDisplayText("1.2.3-beta+build.4") == "1.2.3-beta+build.4")
    #expect(packageVersionDisplayText("") == "")
}
