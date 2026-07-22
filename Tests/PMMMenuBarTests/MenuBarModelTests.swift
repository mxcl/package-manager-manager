import Foundation
import PMMCore
import Testing
@testable import PMMMenuBar

@Test func localProgressRelayCoalescesBurstAndFinishesWithDelayedFinalChunk() {
    let published = LockedStrings()
    let relay = MenuBarActionProgressRelay(interval: 60) { published.append($0) }
    relay.recordStarted(command: "brew upgrade git")

    relay.append("first\n")
    relay.append("delayed final\n")

    #expect(published.values == ["first\n"])
    #expect(relay.finish() == MenuBarActionProgressResult(
        command: "brew upgrade git",
        output: "first\ndelayed final\n"
    ))
    #expect(published.values == ["first\n"])
}

@Test func lateStartedCommandPreservesAlreadyPublishedOutput() {
    let runID = UUID()
    let action = PackageHostRunningAction(
        runID: runID,
        kind: .update,
        packageID: "brew:git",
        displayName: "git",
        output: "first output\n"
    )

    let updated = menuBarAction(action, applyingStartedCommand: "brew upgrade git")

    #expect(updated.runID == runID)
    #expect(updated.command == "brew upgrade git")
    #expect(updated.output == "first output\n")
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [String]()

    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

@Test func menuStateShowsLoadingBeforeInventoryExists() {
    let state = MenuBarMenuState()

    #expect(state.statusSymbolName == "shippingbox")
    #expect(state.rows == [.loading])
}

@Test func menuStateShowsEmptyOutdatedInventory() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .homebrew, name: "git", installedVersion: "2.0.0", latestVersion: "2.0.0")
    ]))

    #expect(state.statusSymbolName == "shippingbox")
    #expect(state.rows == [.empty])
}

@Test func menuStateShowsSortedOutdatedPackageRows() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .npm, name: "zeta", installedVersion: "1.0.0", latestVersion: "2.0.0"),
        ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1.0.0", latestVersion: "1.2.0"),
        ManagedPackage(manager: .npm, identifier: "npm:alpha", displayName: "alpha", installedVersion: "1.0.0", latestVersion: "3.0.0"),
    ]))

    #expect(state.statusSymbolName == "shippingbox.fill")
    #expect(state.rows == [
        .package(MenuBarPackageRow(ecosystemTitle: "Homebrew", ecosystemIcon: .asset(name: "EcosystemHomebrew", fallbackSystemName: "mug"), name: "git", installedVersion: "1.0.0", latestVersion: "1.2.0")),
        .package(MenuBarPackageRow(ecosystemTitle: "npm", ecosystemIcon: .asset(name: "EcosystemJavaScript", fallbackSystemName: "curlybraces"), name: "alpha", installedVersion: "1.0.0", latestVersion: "3.0.0")),
        .package(MenuBarPackageRow(ecosystemTitle: "npm", ecosystemIcon: .asset(name: "EcosystemJavaScript", fallbackSystemName: "curlybraces"), name: "zeta", installedVersion: "1.0.0", latestVersion: "2.0.0")),
    ])
}

@Test func advisoryAppsAppearWithoutChangingMenuBarStatus() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(
            manager: .macApp,
            identifier: "mac-app:com.example.Fork",
            displayName: "Fork",
            installedVersion: "1.0.0",
            latestVersion: "2.0.0",
            appProvenance: .direct
        )
    ]))

    #expect(state.statusSymbolName == "shippingbox")
    #expect(state.rows == [
        .package(MenuBarPackageRow(ecosystemTitle: "DIY", ecosystemIcon: .system(name: "wrench.and.screwdriver"), name: "Fork", installedVersion: "1.0.0", latestVersion: "2.0.0"))
    ])
}

@Test func menuBarEcosystemIconsMatchPackageCategoriesAndAppSources() {
    #expect(menuBarEcosystemIcon(for: ManagedPackage(manager: .homebrew, identifier: "brew:cask:fork", displayName: "Fork", installedVersion: "1", latestVersion: "2")) == .system(name: "macwindow"))
    #expect(menuBarEcosystemIcon(for: ManagedPackage(manager: .macApp, name: "Store", installedVersion: "1", latestVersion: "2", appProvenance: .appStore)) == .system(name: "appstore"))
    #expect(menuBarEcosystemIcon(for: ManagedPackage(manager: .mise, name: "python", installedVersion: "1", latestVersion: "2")) == .asset(name: "EcosystemPython", fallbackSystemName: "arrow.forward.to.line"))
}

@Test func menuBarCommandValidationAcceptsSupportedActions() throws {
    let outdated = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1.0.0", latestVersion: "2.0.0")
    let catalogOnly = ManagedPackage(manager: .npm, name: "eslint", installedVersion: nil, latestVersion: "9.0.0")
    let snapshot = PackageHostSnapshot(inventory: PackageInventory(packages: [outdated]), catalogPackages: [catalogOnly])

    #expect(menuBarCommandPackage(id: catalogOnly.id, kind: .install, snapshot: snapshot) == catalogOnly)
    #expect(menuBarCommandPackage(id: outdated.id, kind: .update, snapshot: snapshot) == outdated)
    #expect(menuBarCommandPackage(id: outdated.id, kind: .uninstall, snapshot: snapshot) == outdated)
}

@Test func menuBarCommandValidationRejectsUnsupportedActions() {
    let current = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "2.0.0", latestVersion: "2.0.0")
    let catalogOnly = ManagedPackage(manager: .homebrew, name: "curl", installedVersion: nil, latestVersion: "8.0.0")
    let busy = PackageHostSnapshot(
        inventory: PackageInventory(packages: [current]),
        runningAction: PackageHostRunningAction(kind: .update, packageID: current.id, displayName: "git")
    )
    let snapshot = PackageHostSnapshot(inventory: PackageInventory(packages: [current, catalogOnly]))

    #expect(menuBarCommandPackage(id: current.id, kind: .update, snapshot: snapshot) == nil)
    #expect(menuBarCommandPackage(id: catalogOnly.id, kind: .install, snapshot: snapshot) == nil)
    #expect(menuBarCommandPackage(id: catalogOnly.id, kind: .uninstall, snapshot: snapshot) == nil)
    #expect(menuBarCommandPackage(id: current.id, kind: .uninstall, snapshot: busy) == nil)
}

@Test func menuBarUpdateAllOnlyIncludesSupportedOutdatedPackagesWhenIdle() {
    let supported = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1.0.0", latestVersion: "2.0.0")
    let unsupported = ManagedPackage(manager: .rustup, name: "rustup", installedVersion: "1.0.0", latestVersion: "2.0.0")
    let current = ManagedPackage(manager: .npm, name: "eslint", installedVersion: "9.0.0", latestVersion: "9.0.0")
    let snapshot = PackageHostSnapshot(inventory: PackageInventory(packages: [supported, unsupported, current]))
    let busy = PackageHostSnapshot(
        inventory: PackageInventory(packages: [supported]),
        runningAction: PackageHostRunningAction(kind: .update, packageID: supported.id, displayName: "git")
    )

    #expect(menuBarCommandUpdateAllPackages(snapshot: snapshot) == [supported])
    #expect(menuBarCommandUpdateAllPackages(snapshot: busy).isEmpty)
}

@Test func menuBarInstallManyOnlyIncludesSupportedCatalogPackagesWhenIdle() {
    let installed = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "2.0.0", latestVersion: "2.0.0")
    let brew = ManagedPackage(manager: .homebrew, name: "bat", installedVersion: nil, latestVersion: "1.0.0")
    let npm = ManagedPackage(manager: .npm, name: "eslint", installedVersion: nil, latestVersion: "9.0.0")
    let unsupported = ManagedPackage(manager: .uvx, name: "ruff", installedVersion: nil, latestVersion: "1.0.0")
    let snapshot = PackageHostSnapshot(
        inventory: PackageInventory(packages: [installed]),
        catalogPackages: [brew, npm, unsupported]
    )
    let busy = PackageHostSnapshot(
        inventory: PackageInventory(packages: []),
        catalogPackages: [brew],
        runningAction: PackageHostRunningAction(kind: .install, packageID: brew.id, displayName: "bat")
    )

    #expect(menuBarCommandInstallPackages(ids: [installed.id, brew.id, npm.id, unsupported.id], snapshot: snapshot) == [brew, npm])
    #expect(menuBarCommandInstallPackages(ids: [brew.id], snapshot: busy).isEmpty)
}

@Test func menuBarRefreshesOnLaunchWhenInventoryIsMissingIncompleteOrStale() {
    let now = Date(timeIntervalSince1970: 10_000)
    let fresh = PackageInventory(generatedAt: now.addingTimeInterval(-(menuBarRefreshInterval - 1)), packages: [])
    let stale = PackageInventory(generatedAt: now.addingTimeInterval(-menuBarRefreshInterval), packages: [])
    let catalog = [ManagedPackage(manager: .homebrew, name: "git", installedVersion: nil, latestVersion: "1")]

    #expect(menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot(), now: now))
    #expect(menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot(inventory: fresh), now: now))
    #expect(!menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot(inventory: fresh, catalogPackages: catalog), now: now))
    #expect(menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot(inventory: stale, catalogPackages: catalog), now: now))
    #expect(menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot(
        inventory: fresh,
        catalogPackages: catalog,
        loadingManagers: [.homebrew]
    ), now: now))
}

@Test func managerScanResultReplacesOnlyItsPackagesAtStableGenerationDate() {
    let generatedAt = Date(timeIntervalSince1970: 100)
    let oldBrew = ManagedPackage(manager: .homebrew, name: "old", installedVersion: "1", latestVersion: nil)
    let npm = ManagedPackage(manager: .npm, name: "npm", installedVersion: "1", latestVersion: nil)
    let newBrew = ManagedPackage(manager: .homebrew, name: "new", installedVersion: "2", latestVersion: nil)
    let snapshot = PackageHostSnapshot(inventory: PackageInventory(packages: [oldBrew, npm]))

    let merged = menuBarSnapshot(
        snapshot,
        merging: PackageManagerScanResult(manager: .homebrew, packages: [newBrew]),
        generatedAt: generatedAt,
        errors: ["warning"]
    )

    #expect(merged.inventory?.generatedAt == generatedAt)
    #expect(merged.inventory?.packages == [newBrew, npm])
    #expect(merged.inventory?.errors == ["warning"])
}

@Test func successfulActionsUpdateSnapshotImmediately() {
    let installed = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let catalog = ManagedPackage(manager: .npm, name: "eslint", installedVersion: nil, latestVersion: "9")
    var snapshot = PackageHostSnapshot(
        inventory: PackageInventory(packages: [installed]),
        catalogPackages: [catalog]
    )

    snapshot = menuBarSnapshot(snapshot, applyingSuccessfulAction: .install, package: catalog)
    #expect(snapshot.inventory?.packages.first { $0.identifier == catalog.identifier }?.installedVersion == "9")

    snapshot = menuBarSnapshot(snapshot, applyingSuccessfulAction: .update, package: installed)
    #expect(snapshot.inventory?.packages.first { $0.identifier == installed.identifier }?.installedVersion == "2")
    #expect(snapshot.inventory?.packages.first { $0.identifier == installed.identifier }?.isOutdated == false)

    snapshot = menuBarSnapshot(snapshot, applyingSuccessfulAction: .uninstall, package: installed)
    #expect(snapshot.inventory?.packages.contains { $0.identifier == installed.identifier } == false)
}

@Test func uninstallingManagedPythonKeepsOtherInstalledVersions() {
    let python = ManagedPackage(
        manager: .uv,
        name: "uv:cpython:3.13",
        installedVersion: "3.13.2",
        installedVersions: ["3.13.2", "3.13.1"],
        latestVersion: "3.13.2",
        summary: "uv-managed Python"
    )
    let snapshot = menuBarSnapshot(
        PackageHostSnapshot(inventory: PackageInventory(packages: [python])),
        applyingSuccessfulAction: .uninstall,
        package: python
    )

    #expect(snapshot.inventory?.packages.first?.installedVersion == "3.13.1")
    #expect(snapshot.inventory?.packages.first?.installedVersions == ["3.13.1"])
}
