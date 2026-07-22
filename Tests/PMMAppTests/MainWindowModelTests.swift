import Foundation
import AppKit
import PMMCore
import Testing
@testable import PMMApp

@MainActor
@Test func modelDefaultsToHomeSection() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)

    #expect(model.selectedSection == .home)
    #expect(MainWindowSection.librarySections.first == .home)
    #expect(RemoteHostSection.allCases == [.installed, .outdated])
}

@Test func terminalOutputStripsANSIEscapesAndReplacesCarriageReturnLine() {
    let output = mainWindowTerminalAttributedOutput("old\r\u{1B}[32mnew\u{1B}[0m\u{1B}[K\n")

    #expect(output.string == "new\n")
    #expect(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) is NSColor)
}

@Test func terminalOutputCarriageReturnOverwritesWithoutImplicitErase() {
    let output = mainWindowTerminalAttributedOutput("abcdef\rxy")

    #expect(output.string == "xycdef")
}

@Test func terminalOutputHandlesCursorUpLineReplacement() {
    let output = mainWindowTerminalAttributedOutput("Downloading\nExtracting\n\u{1B}[1A\u{1B}[2KInstalling\n")

    #expect(output.string == "Downloading\nInstalling\n")
}

@Test func terminalOutputHandlesRepeatedMultilineProgressReplacement() {
    let output = mainWindowTerminalAttributedOutput("""
    Header
    : Bottle pitchfork ## Downloading 1.3MB
    : Bottle usage #### Downloading
    \u{1B}[2A\u{1B}[G\u{1B}[K: Bottle pitchfork ### Downloading 1.8MB
    \u{1B}[K: Bottle usage ##### Downloaded
    \u{1B}[2F\u{1B}[K: Bottle pitchfork #### Downloading 2.1MB
    \u{1B}[K: Bottle usage ##### Downloaded
    """)

    #expect(output.string == """
    Header
    : Bottle pitchfork #### Downloading 2.1MB
    : Bottle usage ##### Downloaded
    """)
}

@Test func terminalOutputCarriageReturnTargetsCurrentPhysicalRowAfterWrap() {
    let output = mainWindowTerminalAttributedOutput(String(repeating: "a", count: 82) + "\rxy\u{1B}[K")

    #expect(output.string == String(repeating: "a", count: 80) + "\nxy")
}

@Test func terminalOutputCursorMovementAccountsForEightyColumnWraps() {
    let longProgress = String(repeating: "a", count: 90)
    let output = mainWindowTerminalAttributedOutput("""
    \(longProgress)
    status
    \u{1B}[3A\u{1B}[2Kdone
    """)

    #expect(output.string == "done\n" + String(repeating: "a", count: 10) + "\nstatus")
}

@Test func terminalOutputEraseLineDoesNotDeleteFollowingRows() {
    let output = mainWindowTerminalAttributedOutput("first\nsecond\nthird\n\u{1B}[2A\u{1B}[2Kreplacement")

    #expect(output.string == "first\nreplacement\nthird")
}

@Test func terminalOutputSupportsTrueColorAndWideCharacters() {
    let output = mainWindowTerminalAttributedOutput("\u{1B}[38;2;12;34;56m✔\u{1B}[0m ok")

    #expect(output.string == "✔ ok")
    #expect(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) is NSColor)
}

@Test func terminalOutputGroupsContiguousStylesIntoRuns() {
    let uniform = mainWindowTerminalAttributedOutput(String(repeating: "a", count: 10_000))
    let mixed = mainWindowTerminalAttributedOutput("plain \u{1B}[1;32mbold green\u{1B}[0m plain")

    #expect(attributeRunCount(in: uniform) == 1)
    #expect(attributeRunCount(in: mixed) == 3)
}

private func attributeRunCount(in string: NSAttributedString) -> Int {
    var count = 0
    string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { _, _, _ in count += 1 }
    return count
}

@Test func terminalOutputRewritesExactlyEightyColumnProgressRows() {
    func progress(_ name: String, marks: Int, status: String) -> String {
        let prefix = "\u{1B}[34m: \u{1B}[0mBottle \(name)"
        let visiblePrefix = ": Bottle \(name)"
        let suffix = "\(String(repeating: "#", count: marks)) \(status)"
        return prefix + String(repeating: " ", count: 80 - visiblePrefix.count - suffix.count) + suffix
    }
    let firstAlpha = progress("alpha (1.0.0)", marks: 2, status: "Downloading 1.2MB/8.0MB")
    let firstBeta = progress("beta (2.0.0)", marks: 8, status: "Downloading 2.1MB/4.0MB")
    let finalAlpha = progress("alpha (1.0.0)", marks: 10, status: "Downloaded 8.0MB")
    let finalBeta = progress("beta (2.0.0)", marks: 10, status: "Downloaded 4.0MB")
    let output = "header\r\n" + firstAlpha + "\r\n" + firstBeta + "\r\n"
        + "\u{1B}[2A\r\u{1B}[2K" + finalAlpha + "\r\n"
        + "\r\u{1B}[2K" + finalBeta + "\r\n"

    let rendered = mainWindowTerminalAttributedOutput(output).string

    #expect(mainWindowTerminalAttributedOutput(firstAlpha).string == firstAlpha.replacingOccurrences(of: "\u{1B}[34m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: ""))
    #expect(rendered.contains("header"))
    #expect(rendered.contains("Bottle alpha (1.0.0)"))
    #expect(rendered.contains("Downloaded 8.0MB"))
    #expect(rendered.contains("Downloaded 4.0MB"))
}

@MainActor
@Test func terminalDemoPreservesCompletedProgressAndEarlierOutput() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: root)
    )

    model.showTerminalDemo()
    let rendered = mainWindowTerminalAttributedOutput(model.packageActionOutput).string

    #expect(rendered.contains("==> Downloading https://ghcr.io/"))
    #expect(rendered.contains("Bottle alpha (1.0.0)"))
    #expect(rendered.contains("Bottle beta (2.0.0)"))
    #expect(rendered.contains("Downloaded 8.0MB"))
    #expect(rendered.contains("Downloaded 4.0MB"))
    #expect(!rendered.contains(".1MB/\n4.0MB"))
}

@Test func terminalOutputDoesNotWrapHomebrewManifestLineBeforeEightyColumns() {
    let line = "==> Downloading https://ghcr.io/v2/homebrew/core/talosctl/manifests/1.13.6"
    let output = mainWindowTerminalAttributedOutput(line)

    #expect(line.count < 80)
    #expect(output.string == line)
}

@Test func terminalScrollViewAllowsForEightyColumnsAndItsScroller() {
    #expect(TerminalOutputTextView.scrollViewWidth > TerminalOutputTextView.eightyColumnWidth)
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

@Test func miseRuntimesAppearInTheirEcosystemSections() {
    let packages = [
        ManagedPackage(manager: .mise, identifier: "mise:node", displayName: "Node.js", installedVersion: "22.17.0", latestVersion: nil),
        ManagedPackage(manager: .mise, identifier: "mise:python", displayName: "Python", installedVersion: "3.13.5", latestVersion: nil),
        ManagedPackage(manager: .mise, identifier: "mise:rust", displayName: "Rust", installedVersion: "1.88.0", latestVersion: nil),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(index.packagesBySection[.javascript]?.map(\.identifier) == ["mise:node"])
    #expect(index.packagesBySection[.python]?.map(\.identifier) == ["mise:python"])
    #expect(index.packagesBySection[.rust]?.map(\.identifier) == ["mise:rust"])
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
        runningAction: PackageHostRunningAction(
            kind: .update,
            packageID: package.id,
            displayName: "git",
            command: "brew upgrade git",
            output: "Already up-to-date\n"
        )
    ))

    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, store: store)

    #expect(model.packages == [package])
    #expect(model.isReloading)
    #expect(model.updatingPackageName == "git")
    #expect(model.packageActionCommand == "brew upgrade git")
    #expect(model.packageActionOutput == "Already up-to-date\n")
    #expect(model.installingPackageName == nil)
    #expect(model.count(for: .outdated) == 1)
    #expect(model.count(for: .newUpdated) == 1)
}

@MainActor
@Test func modelMapsInstallSnapshotToPackageActionOutput() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(manager: .homebrew, name: "curl", installedVersion: nil, latestVersion: "8")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: []),
        catalogPackages: [package],
        runningAction: PackageHostRunningAction(
            kind: .install,
            packageID: package.id,
            displayName: "curl",
            command: "brew install curl",
            output: "Installing curl\n"
        )
    ))

    #expect(model.installingPackageName == "curl")
    #expect(model.packageActionCommand == "brew install curl")
    #expect(model.packageActionOutput == "Installing curl\n")
    #expect(model.updatingPackageName == nil)
}

@MainActor
@Test func failedPackageActionStaysAvailableUntilDismissed() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let inventory = PackageInventory(packages: [package])

    model.apply(snapshot: PackageHostSnapshot(
        inventory: inventory,
        runningAction: PackageHostRunningAction(
            kind: .update,
            packageID: package.id,
            displayName: "git",
            command: "brew upgrade git",
            output: "Updating git\n"
        )
    ))
    model.apply(snapshot: PackageHostSnapshot(
        inventory: inventory,
        errorMessage: "Update failed"
    ))

    #expect(model.updatingPackageName == nil)
    #expect(model.packageActionCommand == "brew upgrade git")
    #expect(model.packageActionOutput == "Updating git\n")
    #expect(model.packageActionError == "Update failed")

    model.dismissPackageAction()

    #expect(model.packageActionCommand == nil)
    #expect(model.packageActionOutput == "")
    #expect(model.packageActionError == nil)
}

@MainActor
@Test func localActionOutputAcceptsOnlyTheCurrentAction() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let git = package(.homebrew, "git", installedVersion: "1", latestVersion: "2")
    let curl = package(.homebrew, "curl", installedVersion: "1", latestVersion: "2")
    let inventory = PackageInventory(packages: [git, curl])

    model.apply(snapshot: PackageHostSnapshot(
        inventory: inventory,
        runningAction: PackageHostRunningAction(kind: .update, packageID: git.id, displayName: git.displayName)
    ))
    model.applyHostActionOutput(kind: .update, packageID: git.id, output: "first")
    model.applyHostActionOutput(kind: .uninstall, packageID: git.id, output: "wrong kind")
    model.applyHostActionOutput(kind: .update, packageID: curl.id, output: "wrong package")
    #expect(model.packageActionOutput == "first")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: inventory,
        runningAction: PackageHostRunningAction(kind: .update, packageID: curl.id, displayName: curl.displayName)
    ))
    model.applyHostActionOutput(kind: .update, packageID: git.id, output: "stale")
    model.applyHostActionOutput(kind: .update, packageID: curl.id, output: "second")
    #expect(model.packageActionOutput == "second")

    model.apply(snapshot: PackageHostSnapshot(inventory: inventory))
    model.applyHostActionOutput(kind: .update, packageID: curl.id, output: "late")
    #expect(model.packageActionOutput == "")
}

@MainActor
@Test func consecutiveRunsOfTheSamePackageRejectStaleOutput() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let git = package(.homebrew, "git", installedVersion: "1", latestVersion: "2")
    let inventory = PackageInventory(packages: [git])
    let firstRunID = UUID()
    let secondRunID = UUID()

    model.apply(snapshot: PackageHostSnapshot(
        inventory: inventory,
        runningAction: PackageHostRunningAction(
            runID: firstRunID,
            kind: .update,
            packageID: git.id,
            displayName: git.displayName
        )
    ))
    model.applyHostActionOutput(runID: firstRunID, kind: .update, packageID: git.id, output: "first run")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: inventory,
        runningAction: PackageHostRunningAction(
            runID: secondRunID,
            kind: .update,
            packageID: git.id,
            displayName: git.displayName
        )
    ))
    model.applyHostActionOutput(runID: firstRunID, kind: .update, packageID: git.id, output: "stale first run")
    #expect(model.packageActionOutput == "")

    model.applyHostActionOutput(runID: secondRunID, kind: .update, packageID: git.id, output: "second run")
    #expect(model.packageActionOutput == "second run")
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
    #expect(model.packageActionCommand == nil)
    #expect(model.packageActionOutput == "")
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
    #expect(model.discoverPackageIDToScrollIntoView == nil)
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
    #expect(model.discoverPackageIDToScrollIntoView == nil)
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

@Test func packageURLRequestParsesInstallIdentifiers() throws {
    let cask = try #require(MainWindowPackageURLRequest(identifier: "brew:cask:codex"))
    #expect(cask.manager == .homebrew)
    #expect(cask.name == "cask/codex")
    #expect(cask.identifier == "brew:cask:codex")
    #expect(cask.section == .apps)

    let scoped = try #require(MainWindowPackageURLRequest(identifier: "npm:@scope/tool"))
    #expect(scoped.manager == .npm)
    #expect(scoped.name == "@scope/tool")
    #expect(scoped.identifier == "npm:@scope/tool")
    #expect(scoped.section == .javascript)

    let python = try #require(MainWindowPackageURLRequest(identifier: "brew:python@3.13"))
    #expect(python.manager == .homebrew)
    #expect(python.name == "python@3.13")
    #expect(python.identifier == "brew:python@3.13")

    let skill = try #require(MainWindowPackageURLRequest(identifier: "skills:global:find-skills"))
    #expect(skill.manager == .skills)
    #expect(skill.name == "find-skills")
    #expect(skill.section == .skills)
    #expect(MainWindowPackageURLRequest(identifier: "skills:project:local-skill") == nil)
}

@Test func dashboardBlogIndexDecodesCategoriesAndIcons() throws {
    let data = """
    {
      "posts": [
        {
          "slug": "agent-pack",
          "title": "Agent Pack",
          "subtitle": "10 agent CLIs and assistants",
          "category": "pack",
          "systemImage": "sparkles",
          "publishedAt": "Jun 4, 2026",
          "url": "https://mxcl.dev/package-manager-manager/blog/agent-pack/"
        },
        {
          "slug": "introducing-package-manager-manager",
          "title": "Introducing Package Manager Manager",
          "subtitle": "See what every package manager installed",
          "category": "blog",
          "systemImage": "square.grid.2x2",
          "publishedAt": "Jul 9, 2026",
          "url": "https://mxcl.dev/package-manager-manager/blog/introducing-package-manager-manager/"
        }
      ]
    }
    """.data(using: .utf8)!

    let index = try JSONDecoder().decode(DashboardBlogIndex.self, from: data)

    #expect(index.posts.map(\.category) == [.pack, .blog])
    #expect(index.posts.map(\.systemImage) == ["sparkles", "square.grid.2x2"])
    #expect(index.posts[1].imageURL.absoluteString == "https://mxcl.dev/package-manager-manager/blog/introducing-package-manager-manager/hero.png")
}

@MainActor
@Test func packageInstallURLAsksForConfirmation() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let bat = ManagedPackage(manager: .homebrew, name: "bat", installedVersion: nil, latestVersion: "1", category: "developer-tools")
    let eslint = ManagedPackage(manager: .npm, name: "eslint", installedVersion: nil, latestVersion: "9", category: "developer-tools")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: []),
        catalogPackages: [bat, eslint],
        isRefreshing: false
    ))

    #expect(model.openPackageURL(URL(string: "pkgmgrmgr://install?package=brew%3Abat&package=npm%3Aeslint")!))
    #expect(model.pendingInstallPackConfirmation == MainWindowInstallPackConfirmation(packageIDs: [bat.id, eslint.id], packageCount: 2))
    #expect(model.selectedPackage == bat)

    model.cancelPendingInstallPack()

    #expect(model.pendingInstallPackConfirmation == nil)
}

@MainActor
@Test func discoverPackageOpensInAppBeforeInstallConfirmation() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = ManagedPackage(
        manager: .homebrew,
        identifier: "brew:bat",
        installedVersion: nil,
        latestVersion: "1",
        category: "developer-tools"
    )
    let discovered = DiscoverFeedPackage(
        id: package.identifier,
        displayName: package.displayName,
        agentSummary: "A better cat",
        manager: "homebrew",
        category: "developer-tools",
        homepage: nil,
        installURL: URL(string: "pkgmgrmgr://install?package=brew%3Abat")
    )

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: []),
        catalogPackages: [package],
        isRefreshing: false
    ))

    #expect(model.openDiscoverPackage(discovered))
    #expect(model.selectedPackage == package)
    #expect(model.pendingInstallPackConfirmation == nil)
    #expect(model.discoverPackageIDToScrollIntoView == package.id)

    model.select(package)
    #expect(model.discoverPackageIDToScrollIntoView == nil)

    #expect(model.openDiscoverPackage(discovered, installing: true))
    #expect(model.selectedPackage == package)
    #expect(model.discoverPackageIDToScrollIntoView == package.id)
    #expect(model.pendingInstallPackConfirmation == MainWindowInstallPackConfirmation(
        packageIDs: [package.id],
        packageCount: 1
    ))
}

@MainActor
@Test func discoverPackagesReflectInstalledInventoryState() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let installed = ManagedPackage(
        manager: .homebrew,
        identifier: "brew:bat",
        installedVersion: "1",
        latestVersion: "1"
    )
    let discovered = DiscoverFeedPackage(
        id: installed.identifier,
        displayName: installed.displayName,
        agentSummary: "A better cat",
        manager: "homebrew",
        category: "developer-tools",
        homepage: nil,
        installURL: URL(string: "pkgmgrmgr://install?package=brew%3Abat")
    )
    let missing = DiscoverFeedPackage(
        id: "brew:ripgrep",
        displayName: "ripgrep",
        agentSummary: "Search tool",
        manager: "homebrew",
        category: "developer-tools",
        homepage: nil,
        installURL: URL(string: "pkgmgrmgr://install?package=brew%3Aripgrep")
    )

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [installed]),
        catalogPackages: [],
        isRefreshing: false
    ))

    #expect(model.isDiscoverPackageInstalled(discovered))
    #expect(!model.isDiscoverPackageInstalled(missing))
}

@MainActor
@Test func discoverPackageScrollRequestSurvivesInventoryLoading() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: root),
        bundledCatalog: []
    )
    let package = ManagedPackage(
        manager: .homebrew,
        identifier: "brew:bat",
        installedVersion: nil,
        latestVersion: "1",
        category: "developer-tools"
    )
    let discovered = DiscoverFeedPackage(
        id: package.identifier,
        displayName: package.displayName,
        agentSummary: "A better cat",
        manager: "homebrew",
        category: "developer-tools",
        homepage: nil,
        installURL: nil
    )

    #expect(!model.openDiscoverPackage(discovered))
    #expect(model.discoverPackageIDToScrollIntoView == nil)

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: []),
        catalogPackages: [package],
        isRefreshing: false
    ))

    #expect(model.selectedPackage == package)
    #expect(model.discoverPackageIDToScrollIntoView == package.id)
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
        package(.skills, "example"),
        ManagedPackage(
            manager: .homebrew,
            identifier: "brew:cask:visual-studio-code",
            displayName: "visual-studio-code",
            installedVersion: "1.0.0",
            latestVersion: "1.0.0"
        ),
        ManagedPackage(
            manager: .macApp,
            identifier: "mac-app:com.example.Fork",
            displayName: "Fork",
            installedVersion: "2.0.0",
            latestVersion: "2.1.0",
            bundleIdentifier: "com.example.Fork",
            appProvenance: .direct
        ),
        package(.npm, "alpha"),
        package(.npm, "beta"),
    ]
    let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)

    #expect(MainWindowSection.managerSections.map(\.title) == ["Apps", "Homebrew", "JavaScript", "Python", "Rust", "Skills"])
    #expect(index.packagesBySection[.rust]?.map(\.displayName) == ["ripgrep", "rustup"])
    #expect(index.packagesBySection[.homebrew]?.map(\.displayName) == ["git", "visual-studio-code"])
    #expect(index.packagesBySection[.apps]?.map(\.displayName) == ["Fork", "visual-studio-code"])
    #expect(index.packagesBySection[.javascript]?.map(\.displayName) == ["acorn", "alpha", "beta", "zeta"])
    #expect(index.packagesBySection[.python]?.map(\.displayName) == ["python", "ruff"])
    #expect(index.packagesBySection[.skills]?.map(\.displayName) == ["example"])
}

@Test func appStoreAppsUseTheBundledEcosystemMark() {
    #expect(mainWindowMacAppMark(for: .appStore) == .asset("EcosystemAppStore"))
    #expect(mainWindowMacAppMark(for: .direct) == .text("DIY"))
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
@Test func categoryCatalogPackagesUseInstalledStateForActions() throws {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let installed = ManagedPackage(
        manager: .homebrew,
        name: "git",
        installedVersion: "2.50.0",
        latestVersion: "2.50.0",
        installLocation: "/opt/homebrew/Cellar/git/2.50.0"
    )
    let catalog = ManagedPackage(
        manager: .homebrew,
        name: "git",
        installedVersion: nil,
        latestVersion: "2.51.0",
        category: "developer-tools",
        lastUpdatedAt: "2026-06-01T00:00:00Z"
    )

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [installed]),
        catalogPackages: [catalog],
        isRefreshing: false
    ))
    model.selectSection(.developerTools)

    let displayed = try #require(model.displayedPackages.first)
    #expect(displayed.id == installed.id)
    #expect(displayed.installedVersion == "2.50.0")
    #expect(displayed.latestVersion == "2.51.0")
    #expect(!model.canInstall(displayed))
    #expect(PackageUninstaller.supports(displayed))
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
@Test func dashboardWaitsForMissingManagersButNotBackgroundFreshness() {
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
    let package = package(.npm, "eslint")

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [package]),
        isRefreshing: true,
        loadingManagers: [.homebrew]
    ))

    #expect(model.dashboardIsLoadingData)
    #expect(model.isLoadingCount(for: .homebrew))
    #expect(!model.isLoadingCount(for: .javascript))

    model.apply(snapshot: PackageHostSnapshot(
        inventory: PackageInventory(packages: [package]),
        isRefreshing: true,
        loadingManagers: []
    ))

    #expect(model.isReloading)
    #expect(!model.dashboardIsLoadingData)
    #expect(!model.isLoadingCount(for: .homebrew))
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
    #expect(model.discoverPackageIDToScrollIntoView == nil)

    model.consumeDiscoverPackageScrollRequest()

    #expect(model.discoverPackageIDToScrollIntoView == nil)
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

@MainActor
@Test func dashboardUsesPersistedCatalogBeforeInventoryLoads() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
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
    let store = PackageHostStore(directory: root)
    try store.save(PackageHostSnapshot(
        catalogPackages: [recommended, newPackage],
        isRefreshing: true,
        loadingManagers: Set(PackageManagerKind.allCases)
    ))

    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: store
    )

    #expect(model.dashboardIsLoadingData)
    #expect(!model.dashboardCatalogIsLoading)
    #expect(model.dashboardWhatsNewPackages == [newPackage])
    #expect(model.dashboardRecommendedPackages == [recommended])
    #expect(model.visibleCategorySections.contains(.developerTools))
}

@MainActor
@Test func dashboardUsesBundledCatalogBeforeHostSnapshotExists() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = ManagedPackage(
        manager: .homebrew,
        name: "ripgrep",
        installedVersion: nil,
        latestVersion: "1",
        category: "developer-tools",
        pulseKind: "updated"
    )

    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: root),
        bundledCatalog: [package]
    )

    #expect(model.dashboardIsLoadingData)
    #expect(!model.dashboardCatalogIsLoading)
    #expect(model.dashboardRecommendedPackages == [package])
    #expect(model.visibleCategorySections.contains(.developerTools))
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

@Test func advisoryAppLinksExposeTheirUpdateDestination() {
    let links = mainWindowLinks(for: ManagedPackage(
        manager: .macApp,
        identifier: "mac-app:com.example.Fork",
        displayName: "Fork",
        installedVersion: "1.0.0",
        latestVersion: "2.0.0",
        bundleIdentifier: "com.example.Fork",
        appProvenance: .direct,
        advisoryURL: "https://example.com/download"
    ))

    #expect(links.map(\.tab) == [.update])
    #expect(links.first?.url.absoluteString == "https://example.com/download")
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

@Test func outdatedBrowserLinksShowChangelogAfterExternalURLs() {
    let links = mainWindowBrowserLinks(for: ManagedPackage(
        manager: .homebrew,
        name: "pkg",
        installedVersion: "1.0.0",
        latestVersion: "2.0.0",
        homepage: "https://example.com",
        docs: "https://example.com/docs",
        repo: "https://github.com/foo/bar"
    ))

    #expect(links.map(\.title) == ["Home", "Repo", "Docs", "Registry", "Changelog"])
    #expect(mainWindowSelectedBrowserLink(in: links, selectedTab: nil)?.title == "Changelog")
    #expect(mainWindowSelectedBrowserLink(in: links, selectedTab: .releases)?.title == "Changelog")
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

@MainActor
@Test func remoteHostsPersistRejectDuplicatesAndRemoveCleanly() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = MainWindowRemoteRunner(response: response)
    let model = MainWindowModel(userDefaults: defaults, remoteClient: RemoteSSHClient(runner: runner))
    #expect(!model.hasMultipleHosts)
    #expect(!model.showsHostManagement)

    let host = try model.saveRemoteHost(name: "Build Mac", destination: "builder")
    #expect(model.hasMultipleHosts)
    #expect(MainWindowModel.sidebarHostName(
        localHostName: "maliwan",
        fallback: "customer.example.isp.invalid"
    ) == "Maliwan")
    #expect(MainWindowModel.droppingLocalSuffix("workstation.local") == "workstation")
    model.showHostManagement()
    #expect(model.showsHostManagement)
    #expect(throws: RemoteHostConfigurationError.duplicateDestination) {
        try model.saveRemoteHost(name: nil, destination: "builder")
    }
    let restored = MainWindowModel(userDefaults: defaults, remoteClient: RemoteSSHClient(runner: runner))
    #expect(restored.remoteHosts == [host])

    model.selectRemoteHost(host.id, section: .installed)
    model.removeRemoteHost(host.id)
    #expect(model.remoteHosts.isEmpty)
    #expect(!model.hasMultipleHosts)
    #expect(!model.isRemoteSelection)
    #expect(model.selectedSection == .home)
}

@MainActor
@Test func remoteSelectionFiltersInventoryAndGatesLocalInstall() async throws {
    let outdated = package(.npm, "eslint", installedVersion: "1.0.0", latestVersion: "2.0.0")
    let current = package(.homebrew, "wget")
    let response = RemoteControlResponse(inventory: PackageInventory(packages: [outdated, current]))
    let runner = MainWindowRemoteRunner(response: response)
    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        remoteClient: RemoteSSHClient(runner: runner)
    )
    let host = try model.saveRemoteHost(name: "Server", destination: "server")
    await waitForRemoteModel { model.remoteHostStates[host.id]?.inventory != nil }

    model.selectRemoteHost(host.id, section: .outdated)
    #expect(model.sidebarSelection == .remote(hostID: host.id, section: .outdated))
    #expect(model.displayedPackages.map(\.identifier) == [outdated.identifier])
    #expect(model.count(for: .installed, on: host.id) == 2)
    #expect(model.count(for: .outdated, on: host.id) == 1)
    #expect(model.showsUpdateAllOutdatedPackages)
    #expect(!model.canInstall(outdated))
    #expect(!model.showsLocalFilesystemActions)

    model.searchText = "nothing"
    #expect(model.displayedPackages.isEmpty)
    #expect(model.count(for: .outdated, on: host.id) == 0)

    model.searchText = ""
    model.updateAllOutdatedPackages()
    await waitForRemoteModel { runner.invocationCount == 2 }
    #expect(runner.lastArguments?.last?.contains("'remote' 'update-all'") == true)
}

@MainActor
@Test func remoteUninstallRequiresConfirmationAndNamesHost() async throws {
    let installed = package(.npm, "eslint")
    let response = RemoteControlResponse(inventory: PackageInventory(packages: [installed]))
    let runner = MainWindowRemoteRunner(response: response)
    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        remoteClient: RemoteSSHClient(runner: runner)
    )
    let host = try model.saveRemoteHost(name: "Server", destination: "server")
    await waitForRemoteModel { model.remoteHostStates[host.id]?.inventory != nil }
    model.selectRemoteHost(host.id, section: .installed)

    model.uninstall(installed)
    #expect(model.pendingRemoteUninstall == RemoteUninstallConfirmation(host: host, package: installed))
    #expect(runner.invocationCount == 1)

    model.confirmRemoteUninstall()
    await waitForRemoteModel { runner.invocationCount == 2 }
    #expect(model.pendingRemoteUninstall == nil)
    #expect(runner.lastArguments?.last?.contains("'remote' 'uninstall'") == true)
    #expect(model.packageActionCommand?.contains("Server") == false)
    #expect(model.packageActionCommand?.contains("server") == true)
}

@MainActor
@Test func remoteActionOutputIsCappedAndFinallyFlushed() async throws {
    let outdated = package(.npm, "eslint", installedVersion: "1.0.0", latestVersion: "2.0.0")
    let response = RemoteControlResponse(inventory: PackageInventory(packages: [outdated]))
    let runner = MainWindowRemoteRunner(
        response: response,
        progressChunks: ["prefix", String(repeating: "x", count: 100_001)]
    )
    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        remoteClient: RemoteSSHClient(runner: runner)
    )
    let host = try model.saveRemoteHost(name: "Server", destination: "server")
    await waitForRemoteModel { model.remoteHostStates[host.id]?.inventory != nil }
    model.selectRemoteHost(host.id, section: .outdated)

    model.update(outdated)
    await waitForRemoteModel { !model.isRunningAction(on: host.id) && runner.invocationCount == 2 }

    #expect(model.packageActionOutput.count == 100_000)
    #expect(model.packageActionOutput == String(repeating: "x", count: 100_000))
}

@MainActor
private func waitForRemoteModel(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for remote model state")
}

private final class MainWindowRemoteRunner: CommandRunning, @unchecked Sendable {
    private let response: RemoteControlResponse
    private let progressChunks: [String]
    private let lock = NSLock()
    private var invocations = [[String]]()

    init(response: RemoteControlResponse, progressChunks: [String] = ["remote progress\n"]) {
        self.response = response
        self.progressChunks = progressChunks
    }

    var invocationCount: Int { lock.withLock { invocations.count } }
    var lastArguments: [String]? { lock.withLock { invocations.last } }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try result(arguments)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        for chunk in progressChunks { onOutput?(chunk) }
        return try result(arguments)
    }

    private func result(_ arguments: [String]) throws -> CommandResult {
        lock.withLock { invocations.append(arguments) }
        return CommandResult(
            stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
            stderr: "",
            status: 0
        )
    }
}
