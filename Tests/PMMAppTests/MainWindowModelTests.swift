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
    #expect(model.count(for: .outdated) == 1)
    #expect(model.count(for: .newUpdated) == 1)
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
@Test func adjacentPackageSelectionMovesWithinDisplayedPackages() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let packages = [package(.homebrew, "alpha"), package(.homebrew, "beta"), package(.homebrew, "gamma")]

    model.apply(
        inventory: PackageInventory(packages: packages),
        index: PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)
    )
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
    ]

    model.apply(
        inventory: PackageInventory(packages: packages),
        index: PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)
    )

    model.searchText = "Managed Python"
    #expect(model.displayedPackages.map(\.identifier) == ["uv:cpython:3.13"])
    model.searchText = "npm:@scope"
    #expect(model.displayedPackages.map(\.identifier) == ["npm:@scope/tool"])
    model.searchText = "scoped"
    #expect(model.displayedPackages.map(\.identifier) == ["npm:@scope/tool"])
}

@Test func languageSectionsGroupManagersAndSortPackagesAlphabetically() {
    let packages = [
        package(.npm, "zeta"),
        package(.npx, "acorn"),
        package(.uvx, "ruff"),
        package(.uv, "python"),
        package(.cargoInstall, "ripgrep"),
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
    #expect(index.packagesBySection[.rust]?.map(\.displayName) == ["ripgrep"])
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

@Test func outdatedBrowserLinksKeepExternalURLsAfterReleases() {
    let links = mainWindowBrowserLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "1.0.0",
        latestVersion: "2.0.0",
        homepage: "https://example.com",
        docs: "https://example.com/docs",
        repo: "https://github.com/foo/bar"
    ))

    #expect(links.map(\.title) == ["Releases", "Home", "Repo", "Docs"])
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
