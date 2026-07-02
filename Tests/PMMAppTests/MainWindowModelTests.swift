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
    model.selectedLinkTab = .docs
    model.selectSection(.outdated)

    #expect(model.selectedPackage == nil)
    #expect(model.selectedLinkTab == nil)
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

@MainActor
@Test func packageSelectionResetsSelectedBrowserTab() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let first = package(.homebrew, "alpha")
    let second = package(.homebrew, "beta")

    model.apply(
        inventory: PackageInventory(packages: [first, second]),
        index: PackageIndex(packages: [first, second], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )
    model.select(first)
    model.selectedLinkTab = .docs
    model.select(second)

    #expect(model.selectedLinkTab == nil)
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

@Test func languageSectionsGroupManagersAndSortPackagesAlphabetically() {
    let packages = [
        package(.npm, "zeta"),
        package(.npx, "acorn"),
        package(.uvx, "ruff"),
        package(.uv, "python"),
        package(.cargoInstall, "ripgrep"),
        package(.homebrew, "git"),
        package(.npm, "alpha"),
        package(.npm, "beta"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(MainWindowSection.managerSections.map(\.title) == ["Homebrew", "JavaScript", "Python", "Rust"])
    #expect(index.packagesBySection[.rust]?.map(\.name) == ["ripgrep"])
    #expect(index.packagesBySection[.homebrew]?.map(\.name) == ["git"])
    #expect(index.packagesBySection[.javascript]?.map(\.name) == ["acorn", "alpha", "beta", "zeta"])
    #expect(index.packagesBySection[.python]?.map(\.name) == ["python", "ruff"])
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

@Test func packageLinksUseHomepageRepoDocsOrderAndSkipInvalidURLs() {
    let links = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "git",
        installedVersion: nil,
        latestVersion: nil,
        homepage: "https://git-scm.com/",
        docs: "https://git-scm.com/docs",
        repo: "https://github.com/git/git"
    ))

    #expect(links.map(\.tab) == [.homepage, .repo, .docs])
    #expect(links.map(\.url.absoluteString) == ["https://git-scm.com/", "https://github.com/git/git", "https://git-scm.com/docs"])
}

@Test func packageLinksFallBackToRepoThenDocsWhenHomepageIsMissing() {
    let links = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        docs: "https://example.com/docs",
        repo: "https://example.com/repo"
    ))

    #expect(links.first?.tab == .repo)
}

@Test func packageLinksPreferRepoAndDocsOverDuplicateHomepage() {
    let repoLinks = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        homepage: "https://example.com/repo",
        docs: "https://example.com/docs",
        repo: "https://example.com/repo"
    ))
    let docsLinks = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        homepage: "https://example.com/docs",
        docs: "https://example.com/docs",
        repo: "https://example.com/repo"
    ))

    #expect(repoLinks.map(\.tab) == [.repo, .docs])
    #expect(docsLinks.map(\.tab) == [.repo, .docs])
}

@Test func packageLinksSkipInvalidURLs() {
    let links = mainWindowLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        homepage: "not a url",
        docs: "https://example.com/docs",
        repo: "https://example.com/repo"
    ))

    #expect(links.map(\.tab) == [.repo, .docs])
}

@Test func selectedBrowserLinkUsesFirstLinkWhenNoTabIsSelected() {
    let links = mainWindowBrowserLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        docs: "https://example.com/docs",
        repo: "https://example.com/repo"
    ))

    #expect(mainWindowSelectedBrowserLink(in: links, selectedTab: nil)?.tab == .repo)
}

@Test func selectedBrowserLinkFallsBackToFirstAvailableLink() {
    let links = mainWindowBrowserLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: nil,
        latestVersion: nil,
        repo: "https://example.com/repo"
    ))

    #expect(mainWindowSelectedBrowserLink(in: links, selectedTab: .docs)?.tab == .repo)
}

@Test func outdatedGitHubPackageLoadsLatestReleaseNotes() {
    let url = mainWindowReleaseNotesURL(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "1.0.0",
        latestVersion: "2.0.0",
        homepage: "https://example.com",
        docs: "https://github.com/foo/bar/tree/main/docs"
    ))

    #expect(url?.absoluteString == "https://github.com/foo/bar/releases/latest")
}

@Test func currentGitHubPackageDoesNotLoadReleaseNotes() {
    let url = mainWindowReleaseNotesURL(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "2.0.0",
        latestVersion: "2.0.0",
        repo: "https://github.com/foo/bar"
    ))

    #expect(url == nil)
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
