import Foundation
import PMMCore
import Testing
@testable import PMMApp

@MainActor
@Test func modelDefaultsToHomeSection() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)

    #expect(model.selectedSection == .home)
    #expect(MainWindowSection.librarySections.first == .home)
}

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
@Test func modelLoadsPackagesFromHostSnapshotStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PackageHostStore(directory: root)
    let package = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let catalogPackage = ManagedPackage(
        manager: .homebrew,
        name: "new-tool",
        installedVersion: nil,
        latestVersion: "1",
        lastUpdatedAt: "2026-06-01T00:00:00Z",
        pulseKind: "new"
    )
    try store.save(PackageHostSnapshot(
        inventory: PackageInventory(packages: [package]),
        catalogPackages: [catalogPackage],
        isRefreshing: true,
        runningAction: PackageHostRunningAction(kind: .update, packageID: package.id, displayName: "git")
    ))

    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, store: store)

    #expect(model.packages == [package])
    #expect(model.isReloading)
    #expect(model.updatingPackageName == "git")
    #expect(model.installingPackageName == nil)
    #expect(model.count(for: .outdated) == 1)
    #expect(model.count(for: .newUpdated) == 1)
}

@MainActor
@Test func modelCanInstallOnlyCatalogPackagesNotAlreadyInstalled() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let installed = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "1")
    let missing = ManagedPackage(manager: .homebrew, name: "curl", installedVersion: nil, latestVersion: "8")
    let alreadyInstalledCatalog = ManagedPackage(manager: .homebrew, name: "git", installedVersion: nil, latestVersion: "2")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [installed]),
        catalogPackages: [missing, alreadyInstalledCatalog],
        runningAction: PackageHostRunningAction(kind: .install, packageID: missing.id, displayName: "curl")
    ))

    #expect(model.canInstall(missing))
    #expect(!model.canInstall(alreadyInstalledCatalog))
    #expect(model.installingPackageName == "curl")
}

@MainActor
@Test func modelShowsLoadingWhenHostSnapshotIsMissing() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: root)
    )

    #expect(model.isReloading)
    #expect(model.displayedPackages.isEmpty)
    #expect(model.isLoadingCount(for: .homebrew))
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
@Test func updateAllToolbarStateOnlyEnablesForOutdatedSectionWithSupportedPackages() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let supported = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let unsupported = ManagedPackage(manager: .rustup, name: "rustup", installedVersion: "1", latestVersion: "2")

    model.apply(
        inventory: PackageInventory(packages: [supported, unsupported]),
        index: PackageIndex(packages: [supported, unsupported], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )

    #expect(!model.showsUpdateAllOutdatedPackages)
    #expect(!model.canUpdateAllOutdatedPackages)

    model.selectSection(.outdated)

    #expect(model.showsUpdateAllOutdatedPackages)
    #expect(model.canUpdateAllOutdatedPackages)

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [supported, unsupported]),
        runningAction: PackageHostRunningAction(kind: .update, packageID: supported.id, displayName: "git")
    ))

    #expect(!model.canUpdateAllOutdatedPackages)
}

@MainActor
@Test func homeSelectionClearsPackageSelection() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(manager: .homebrew, name: "pkg", installedVersion: "1", latestVersion: "2")

    model.apply(
        inventory: PackageInventory(packages: [package]),
        index: PackageIndex(packages: [package], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )
    model.select(package)
    model.selectedLinkTab = .docs
    model.selectSection(.home)

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
    model.selectSection(.installed)
    model.select(packages[1])

    #expect(model.selectAdjacentPackage(offset: 1))
    #expect(model.selectedPackage?.displayName == "gamma")
    #expect(model.selectAdjacentPackage(offset: 1))
    #expect(model.selectedPackage?.displayName == "gamma")
    #expect(model.selectAdjacentPackage(offset: -1))
    #expect(model.selectedPackage?.displayName == "beta")
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
    #expect(model.packageIDToScrollIntoView == nil)
}

@MainActor
@Test func packageURLSelectsBrewPackage() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, store: PackageHostStore(directory: root))
    let zsh = ManagedPackage(manager: .homebrew, identifier: "brew:zsh", displayName: "zsh", installedVersion: "1", latestVersion: "1")

    model.apply(
        inventory: PackageInventory(packages: [zsh]),
        index: PackageIndex(packages: [zsh], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )

    #expect(model.openPackageURL(URL(string: "pkgmgrmgr://brew/zsh")!))
    #expect(model.selectedSection == .homebrew)
    #expect(model.selectedPackage == zsh)
    #expect(model.packageIDToScrollIntoView == zsh.id)
}

@MainActor
@Test func packageURLSelectionWaitsForInventory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, store: PackageHostStore(directory: root))
    let zsh = ManagedPackage(manager: .homebrew, identifier: "brew:zsh", displayName: "zsh", installedVersion: "1", latestVersion: "1")

    #expect(!model.openPackageURL(URL(string: "pkgmgrmgr://brew/zsh")!))
    #expect(model.selectedSection == .homebrew)
    #expect(model.selectedPackage == nil)

    model.apply(
        inventory: PackageInventory(packages: [zsh]),
        index: PackageIndex(packages: [zsh], catalogPackages: [], newUpdatedLastClickedAt: nil)
    )

    #expect(model.selectedPackage == zsh)
}

@Test func installedSectionSortsPackagesAlphabetically() {
    let packages = [
        package(.npm, "zeta"),
        package(.homebrew, "alpha"),
        package(.uv, "beta"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.installed]?.map(\.displayName) == ["alpha", "beta", "zeta"])
}

@MainActor
@Test func packageSearchMatchesDisplayNameIdentifierAndSummary() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let packages = [
        ManagedPackage(manager: .uv, identifier: "uv:cpython:3.13", displayName: "uv Managed Python 3.13", installedVersion: "3.13.12", latestVersion: nil, summary: "runtime"),
        ManagedPackage(manager: .npm, identifier: "npm:@scope/tool", displayName: "@scope/tool", installedVersion: "1.0.0", latestVersion: nil, summary: "A scoped CLI"),
        ManagedPackage(manager: .homebrew, identifier: "brew:findutils", displayName: "findutils", installedVersion: "4.10.0", latestVersion: nil, executableNames: ["gfind"]),
    ]

    model.apply(
        inventory: PackageInventory(packages: packages),
        index: PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)
    )
    model.selectSection(.installed)

    model.searchText = "Managed Python"
    #expect(model.displayedPackages.map(\.identifier) == ["uv:cpython:3.13"])
    model.searchText = "npm:@scope"
    #expect(model.displayedPackages.map(\.identifier) == ["npm:@scope/tool"])
    model.searchText = "scoped"
    #expect(model.displayedPackages.map(\.identifier) == ["npm:@scope/tool"])
    model.searchText = "gfind"
    #expect(model.displayedPackages.map(\.identifier) == ["brew:findutils"])
}

@MainActor
@Test func packageSearchUpdatesSidebarCounts() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let ripgrep = ManagedPackage(manager: .cargoInstall, name: "ripgrep", installedVersion: "1", latestVersion: "1", summary: "fast search")
    let git = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2", summary: "fast search")
    let ruff = ManagedPackage(manager: .uv, name: "ruff", installedVersion: "1", latestVersion: "1", summary: "lint")
    let newPackage = ManagedPackage(
        manager: .homebrew,
        name: "fd",
        installedVersion: nil,
        latestVersion: "1",
        summary: "fast search",
        category: "developer-tools",
        lastUpdatedAt: "2026-06-01T00:00:00Z",
        pulseKind: "new"
    )
    let recommended = ManagedPackage(
        manager: .homebrew,
        name: "curl",
        installedVersion: nil,
        latestVersion: "1",
        summary: "transfer tool",
        category: "networking",
        lastUpdatedAt: "2026-06-01T00:00:00Z",
        pulseKind: "updated"
    )

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [ripgrep, git, ruff]),
        catalogPackages: [newPackage, recommended],
        isRefreshing: false
    ))
    model.selectSection(.installed)
    model.searchText = "search"

    #expect(model.displayedPackages.map(\.displayName) == ["git", "ripgrep"])
    #expect(model.count(for: .installed) == 2)
    #expect(model.count(for: .outdated) == 1)
    #expect(model.count(for: .rust) == 1)
    #expect(model.count(for: .homebrew) == 1)
    #expect(model.count(for: .python) == 0)
    #expect(model.count(for: .developerTools) == 1)
    #expect(model.count(for: .networking) == 0)
    #expect(model.count(for: .newUpdated) == 1)
}

@Test func languageSectionsGroupManagersAndSortPackagesAlphabetically() {
    let packages = [
        package(.npm, "zeta"),
        package(.npx, "acorn"),
        package(.uvx, "ruff"),
        package(.uv, "python"),
        package(.cargoInstall, "ripgrep"),
        package(.rustup, "rustup"),
        package(.homebrew, "git"),
        ManagedPackage(
            manager: .homebrew,
            identifier: "brew:cask:visual-studio-code",
            displayName: "visual-studio-code",
            installedVersion: "1.0.0",
            latestVersion: "1.0.0"
        ),
        package(.npm, "alpha"),
        package(.npm, "beta"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(MainWindowSection.managerSections.map(\.title) == ["Casks", "Homebrew", "JavaScript", "Python", "Rust"])
    #expect(index.packagesBySection[.rust]?.map(\.displayName) == ["ripgrep", "rustup"])
    #expect(index.packagesBySection[.homebrew]?.map(\.displayName) == ["git", "visual-studio-code"])
    #expect(index.packagesBySection[.casks]?.map(\.displayName) == ["visual-studio-code"])
    #expect(index.packagesBySection[.javascript]?.map(\.displayName) == ["acorn", "alpha", "beta", "zeta"])
    #expect(index.packagesBySection[.python]?.map(\.displayName) == ["python", "ruff"])
}

@Test func outdatedSectionSortsMostOutdatedFirst() {
    let packages = [
        package(.npm, "patch", installedVersion: "1.0.0", latestVersion: "1.0.5"),
        package(.npm, "major", installedVersion: "1.0.0", latestVersion: "3.0.0"),
        package(.npm, "minor", installedVersion: "1.0.0", latestVersion: "1.10.0"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.outdated]?.map(\.displayName) == ["major", "minor", "patch"])
}

@Test func categorySectionsSortPackagesByNewestUpdateFirst() {
    let packages = [
        package(.homebrew, "old", category: "developer-tools", lastUpdatedAt: "2026-01-01T00:00:00Z"),
        package(.homebrew, "new", category: "developer-tools", lastUpdatedAt: "2026-06-01T00:00:00Z"),
        package(.homebrew, "middle", category: "developer-tools", lastUpdatedAt: "2026-03-01T00:00:00Z"),
    ]
    let index = PackageIndex(packages: [], catalogPackages: packages, newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.developerTools]?.map(\.displayName) == ["new", "middle", "old"])
}

@Test func categoryCatalogPackageVersionTextShowsManager() {
    let package = ManagedPackage(
        manager: .npm,
        name: "sherif",
        installedVersion: nil,
        latestVersion: "1.13.0",
        category: "developer-tools"
    )

    #expect(mainWindowVersionText(package, section: .developerTools) == "NPM")
}

@MainActor
@Test func dashboardDataUsesLoadedSnapshot() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let generatedAt = Date(timeIntervalSince1970: 100)
    let outdated = package(.homebrew, "git", installedVersion: "1.0.0", latestVersion: "2.0.0")
    let current = package(.npm, "eslint")
    let python = package(.uv, "ruff")
    let newPackage = ManagedPackage(
        manager: .homebrew,
        name: "mise",
        installedVersion: nil,
        latestVersion: "1",
        category: "developer-tools",
        lastUpdatedAt: "2026-06-03T00:00:00Z",
        pulseKind: "new"
    )
    let recommended = ManagedPackage(
        manager: .homebrew,
        name: "ripgrep",
        installedVersion: nil,
        latestVersion: "1",
        category: "developer-tools",
        lastUpdatedAt: "2026-06-02T00:00:00Z",
        pulseKind: "updated"
    )

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(generatedAt: generatedAt, packages: [outdated, current, python]),
        catalogPackages: [recommended, newPackage],
        isRefreshing: false
    ))

    #expect(!model.dashboardIsLoadingData)
    #expect(model.dashboardInstalledCount == 3)
    #expect(model.dashboardOutdatedCount == 1)
    #expect(model.dashboardActiveEcosystemCount == 3)
    #expect(model.dashboardInstalledThisWeekText == nil)
    #expect(model.dashboardLastUpdatedText?.hasPrefix("Last updated: ") == true)
    #expect(model.dashboardWhatsNewPackages.map(\.displayName) == ["mise"])
    #expect(model.dashboardRecommendedPackages.map(\.displayName) == ["ripgrep"])
}

@MainActor
@Test func dashboardInstalledThisWeekCountsOnlyCurrentInstalledPackages() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
    let thisWeek = week.start.addingTimeInterval(60)
    let beforeThisWeek = week.start.addingTimeInterval(-60)
    let fresh = package(.homebrew, "fresh")
    let old = package(.npm, "old")
    let removed = package(.uv, "removed")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [fresh, old]),
        installedPackageFirstSeenAtByID: [
            fresh.id: thisWeek,
            old.id: beforeThisWeek,
            removed.id: thisWeek,
        ]
    ))

    #expect(model.dashboardInstalledThisWeekText == "+1 this week")
}

@MainActor
@Test func dashboardInstalledThisWeekHidesZeroWithBaselineHistory() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let installed = package(.homebrew, "git")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [installed]),
        installedPackageFirstSeenAtByID: [installed.id: Date(timeIntervalSince1970: 0)]
    ))

    #expect(model.dashboardInstalledThisWeekText == nil)
}

@MainActor
@Test func dashboardPackageOpensItsCategoryAndSelectsPackage() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(
        manager: .homebrew,
        name: "diskwatch",
        installedVersion: nil,
        latestVersion: "1",
        category: "developer-tools",
        lastUpdatedAt: "2026-06-03T00:00:00Z",
        pulseKind: "new"
    )

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: []),
        catalogPackages: [package],
        isRefreshing: false
    ))

    model.openDashboardPackage(package)

    #expect(model.selectedSection == .developerTools)
    #expect(model.selectedPackage == package)
    #expect(model.displayedPackages == [package])
    #expect(model.packageIDToScrollIntoView == package.id)

    model.consumePackageScrollRequest()

    #expect(model.packageIDToScrollIntoView == nil)
}

@MainActor
@Test func dashboardDataIsLoadingSafeWithoutInventory() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: root)
    )

    #expect(model.dashboardIsLoadingData)
    #expect(model.dashboardInstalledCount == nil)
    #expect(model.dashboardOutdatedCount == nil)
    #expect(model.dashboardActiveEcosystemCount == nil)
    #expect(model.dashboardInstalledThisWeekText == nil)
    #expect(model.dashboardLastUpdatedText == nil)
}

@Test func newUpdatedSectionOnlyShowsNewPackages() {
    let newPackage = ManagedPackage(
        manager: .homebrew,
        identifier: "brew:git",
        displayName: "git",
        installedVersion: nil,
        latestVersion: "2.50.0",
        summary: "Distributed revision control",
        category: "developer-tools",
        homepage: "https://git-scm.com/",
        repo: "https://github.com/git/git",
        lastUpdatedAt: "2026-06-01T00:00:00Z",
        pulseKind: "new"
    )
    let updatedPackage = ManagedPackage(
        manager: .homebrew,
        identifier: "brew:curl",
        displayName: "curl",
        installedVersion: nil,
        latestVersion: "8.0.0",
        summary: nil,
        category: "networking",
        homepage: nil,
        repo: nil,
        lastUpdatedAt: "2026-06-02T00:00:00Z",
        pulseKind: "updated"
    )
    let index = PackageIndex(packages: [], catalogPackages: [newPackage, updatedPackage], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.newUpdated] == [newPackage])
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

    #expect(links.map(\.tab) == [.homepage, .repo, .docs, .registry])
    #expect(links.map(\.url.absoluteString) == ["https://git-scm.com/", "https://github.com/git/git", "https://git-scm.com/docs", "https://formulae.brew.sh/formula/git"])
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

    #expect(repoLinks.map(\.tab) == [.repo, .docs, .registry])
    #expect(docsLinks.map(\.tab) == [.repo, .docs, .registry])
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

    #expect(links.map(\.tab) == [.repo, .docs, .registry])
}

@Test func packageRegistryLinksUseKnownPackageRegistryPages() {
    #expect(mainWindowRegistryURLString(for: ManagedPackage(manager: .homebrew, identifier: "brew:git", installedVersion: nil, latestVersion: nil)) == "https://formulae.brew.sh/formula/git")
    #expect(mainWindowRegistryURLString(for: ManagedPackage(manager: .homebrew, identifier: "brew:cask:visual-studio-code", installedVersion: nil, latestVersion: nil)) == "https://formulae.brew.sh/cask/visual-studio-code")
    #expect(mainWindowRegistryURLString(for: ManagedPackage(manager: .npm, identifier: "npm:@scope/tool", installedVersion: nil, latestVersion: nil)) == "https://www.npmjs.com/package/@scope/tool")
    #expect(mainWindowRegistryURLString(for: ManagedPackage(manager: .cargoInstall, identifier: "cargo:ripgrep", installedVersion: nil, latestVersion: nil)) == "https://crates.io/crates/ripgrep")
    #expect(mainWindowRegistryURLString(for: ManagedPackage(manager: .uv, identifier: "uv:tool:ruff", installedVersion: nil, latestVersion: nil)) == "https://pypi.org/project/ruff/")
    #expect(mainWindowRegistryURLString(for: ManagedPackage(manager: .uv, identifier: "uv:cpython:3.13", installedVersion: nil, latestVersion: nil)) == nil)
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

@Test func outdatedBrowserLinksShowReleasesAfterExternalURLs() {
    let links = mainWindowBrowserLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "1.0.0",
        latestVersion: "2.0.0",
        homepage: "https://example.com",
        docs: "https://example.com/docs",
        repo: "https://github.com/foo/bar"
    ))

    #expect(links.map(\.title) == ["Home", "Repo", "Docs", "Registry", "Releases"])
    #expect(mainWindowSelectedBrowserLink(in: links, selectedTab: nil)?.title == "Releases")
    #expect(mainWindowSelectedBrowserLink(in: links, selectedTab: .releases)?.title == "Releases")
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

@Test func browserDisplayURLDropsSchemeAndTrailingSlash() {
    #expect(mainWindowBrowserDisplayURL(URL(string: "https://example.com/docs/")!) == "example.com/docs")
    #expect(mainWindowBrowserDisplayURL(URL(string: "http://example.com")!) == "example.com")
}

@Test func packageLocationsUseInstallAndBinaryPaths() {
    let package = ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "1.0.0",
        latestVersion: nil,
        installLocation: "/opt/homebrew/Cellar/pkg/1.0.0",
        binaryPath: "/opt/homebrew/bin/pkg"
    )

    #expect(mainWindowPackageLocations(for: package) == [
        MainWindowPackageLocation(label: "Install Root", path: "/opt/homebrew/Cellar/pkg/1.0.0"),
        MainWindowPackageLocation(label: "Binary", path: "/opt/homebrew/bin/pkg"),
    ])
}

@Test func executablePathUsesKnownBinaryDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let tool = bin.appendingPathComponent("pkg-tool")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: tool.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let package = ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "1.0.0",
        latestVersion: nil,
        binaryPath: bin.appendingPathComponent("pkg").path
    )

    #expect(mainWindowExecutablePath(named: "pkg-tool", for: package, findExecutable: { _ in nil }) == tool.path)
    #expect(mainWindowExecutablePath(named: "../pkg-tool", for: package, findExecutable: { _ in nil }) == nil)
}

@Test func configurationLocationsShowOnlyMacOSAndUnixPaths() throws {
    let dossier = try JSONDecoder().decode(PackageDossierPage.self, from: Data("""
    {
      "data": {
        "configFileLocations": {
          "macos": "$XDG_CONFIG_HOME/tool/config",
          "unix": ["~/.toolrc", "$HOME/.toolrc", "/etc/toolrc", ".envrc"],
          "linux": "/etc/linux-only",
          "windows": "C:\\\\Users\\\\user\\\\toolrc"
        },
        "credentialsFileLocations": {
          "macos": "~/Library/Application Support/Tool/credentials",
          "unix": ["~/.toolrc", "~/.tool-credentials"],
          "linux": "/etc/linux-secret"
        }
      }
    }
    """.utf8))

    let locations = mainWindowConfigurationLocations(for: dossier) {
        $0.replacingOccurrences(of: "$XDG_CONFIG_HOME", with: "/Users/me/.config")
            .replacingOccurrences(of: "$HOME", with: "/Users/me")
            .replacingOccurrences(of: "~", with: "/Users/me")
    }

    #expect(locations == [
        MainWindowConfigurationLocation(path: "/Users/me/.config/tool/config"),
        MainWindowConfigurationLocation(path: "/Users/me/.toolrc"),
        MainWindowConfigurationLocation(path: "/etc/toolrc"),
        MainWindowConfigurationLocation(path: "/Users/me/Library/Application Support/Tool/credentials"),
        MainWindowConfigurationLocation(path: "/Users/me/.tool-credentials"),
    ])
}

@Test func configurationPathVariablesSkipUnsetSimpleReferences() {
    let environment = ["HOME": "/Users/me"]

    #expect(mainWindowReferencesUnsetEnvironmentVariable("$XDG_CONFIG_HOME/direnv/direnv.toml", environment: environment))
    #expect(mainWindowReferencesUnsetEnvironmentVariable("${XDG_CONFIG_HOME}/direnv/direnv.toml", environment: environment))
    #expect(!mainWindowReferencesUnsetEnvironmentVariable("$HOME/.config/direnv/direnv.toml", environment: environment))
    #expect(!mainWindowReferencesUnsetEnvironmentVariable("${XDG_CONFIG_HOME:-$HOME/.config}/direnv/direnv.toml", environment: environment))
}

@Test func categoryTitleHumanizesPackageCategories() {
    #expect(mainWindowCategoryTitle("developer-tools") == "Developer Tools")
    #expect(mainWindowCategoryTitle("custom-category") == "Custom Category")
    #expect(mainWindowCategoryTitle(nil) == nil)
}

@Test func prepareEditableFileCreatesMissingConfigFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("direnv/direnv.toml").path

    #expect(try mainWindowPrepareEditableFile(at: path) == path)
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func shellPathResolutionKeepsTildeFallbackWhenSimpleVariableIsUnset() {
    let home = NSHomeDirectory()

    #expect(mainWindowResolveShellPaths([
        "$PMM_UNSET_CONFIG_HOME_DO_NOT_SET/direnv/direnv.toml",
        "~/.config/direnv/direnv.toml",
    ]) == ["\(home)/.config/direnv/direnv.toml"])
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
