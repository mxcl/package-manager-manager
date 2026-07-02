import Foundation
import PMMCore
import Testing
@testable import PMMApp

@MainActor
@Test func inventoryApplyDoesNotSelectPackageAutomatically() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(manager: .homebrew, name: "pkg", installedVersion: "1", latestVersion: "1")

    model.apply(
        inventory: PackageInventory(packages: [package]),
        index: PackageIndex(packages: [package], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )

    #expect(model.selectedPackage == nil)
}

@MainActor
@Test func sectionSelectionClearsPackageSelection() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(manager: .homebrew, name: "pkg", installedVersion: "1", latestVersion: "2")

    model.apply(
        inventory: PackageInventory(packages: [package]),
        index: PackageIndex(packages: [package], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )
    model.select(package)
    model.selectSection(.outdated)

    #expect(model.selectedPackage == nil)
}

@MainActor
@Test func adjacentPackageSelectionMovesWithinDisplayedPackages() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let packages = [package(.homebrew, "alpha"), package(.homebrew, "beta"), package(.homebrew, "gamma")]

    model.apply(
        inventory: PackageInventory(packages: packages),
        index: PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)
    )
    model.select(packages[1])

    #expect(model.selectAdjacentPackage(offset: 1))
    #expect(model.selectedPackage?.name == "gamma")
    #expect(model.selectAdjacentPackage(offset: 1))
    #expect(model.selectedPackage?.name == "gamma")
    #expect(model.selectAdjacentPackage(offset: -1))
    #expect(model.selectedPackage?.name == "beta")
}

@Test func installedSectionSortsPackagesAlphabetically() {
    let packages = [
        package(.npm, "zeta"),
        package(.homebrew, "alpha"),
        package(.uv, "beta"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.installed]?.map(\.name) == ["alpha", "beta", "zeta"])
}

@Test func managerSectionsSortPackagesAlphabetically() {
    let packages = [
        package(.npm, "zeta"),
        package(.npm, "alpha"),
        package(.npm, "beta"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.npm]?.map(\.name) == ["alpha", "beta", "zeta"])
}

@Test func outdatedSectionSortsMostOutdatedFirst() {
    let packages = [
        package(.npm, "patch", installedVersion: "1.0.0", latestVersion: "1.0.5"),
        package(.npm, "major", installedVersion: "1.0.0", latestVersion: "3.0.0"),
        package(.npm, "minor", installedVersion: "1.0.0", latestVersion: "1.10.0"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.outdated]?.map(\.name) == ["major", "minor", "patch"])
}

@Test func categorySectionsSortPackagesByNewestUpdateFirst() {
    let packages = [
        package(.homebrew, "old", category: "developer-tools", lastUpdatedAt: "2026-01-01T00:00:00Z"),
        package(.homebrew, "new", category: "developer-tools", lastUpdatedAt: "2026-06-01T00:00:00Z"),
        package(.homebrew, "middle", category: "developer-tools", lastUpdatedAt: "2026-03-01T00:00:00Z"),
    ]
    let index = PackageIndex(packages: [], catalogPackages: packages, newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.developerTools]?.map(\.name) == ["new", "middle", "old"])
}

@Test func packageLinksUseHomepageDocsRepoOrderAndSkipInvalidURLs() {
    let links = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "git",
        installedVersion: nil,
        latestVersion: nil,
        homepage: "https://git-scm.com/",
        docs: "not a url",
        repo: "https://github.com/git/git"
    ))

    #expect(links.map(\.tab) == [.homepage, .repo])
    #expect(links.map(\.url.absoluteString) == ["https://git-scm.com/", "https://github.com/git/git"])
}

@Test func packageLinksFallBackToDocsThenRepoWhenHomepageIsMissing() {
    let links = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        docs: "https://example.com/docs",
        repo: "https://example.com/repo"
    ))

    #expect(links.first?.tab == .docs)
}

private func package(
    _ manager: PackageManagerKind,
    _ name: String,
    installedVersion: String? = "1.0.0",
    latestVersion: String? = "1.0.0",
    category: String? = nil,
    lastUpdatedAt: String? = nil
) -> ManagedPackage {
    ManagedPackage(
        manager: manager,
        name: name,
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        category: category,
        lastUpdatedAt: lastUpdatedAt
    )
}
