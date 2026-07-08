import Foundation
import PMMCore
import Testing
@testable import PMMMenuBar

@Test func menuStateShowsLoadingBeforeInventoryExists() {
    let state = MenuBarMenuState()

    #expect(state.statusSymbolName == "shippingbox.fill")
    #expect(state.rows == [.loading])
}

@Test func menuStateShowsEmptyOutdatedInventory() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .homebrew, name: "git", installedVersion: "2.0.0", latestVersion: "2.0.0")
    ]))

    #expect(state.statusSymbolName == "shippingbox.fill")
    #expect(state.rows == [.empty])
}

@Test func menuStateShowsSortedOutdatedPackageRows() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .npm, name: "zeta", installedVersion: "1.0.0", latestVersion: "2.0.0"),
        ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1.0.0", latestVersion: "1.2.0"),
        ManagedPackage(manager: .npm, identifier: "npm:alpha", displayName: "alpha", installedVersion: "1.0.0", latestVersion: "3.0.0"),
    ]))

    #expect(state.statusSymbolName == "shippingbox")
    #expect(state.rows == [
        .package(MenuBarPackageRow(managerTitle: "Homebrew", name: "git", installedVersion: "1.0.0", latestVersion: "1.2.0")),
        .package(MenuBarPackageRow(managerTitle: "npm", name: "alpha", installedVersion: "1.0.0", latestVersion: "3.0.0")),
        .package(MenuBarPackageRow(managerTitle: "npm", name: "zeta", installedVersion: "1.0.0", latestVersion: "2.0.0")),
    ])
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

@Test func menuBarRefreshesOnLaunchOnlyWhenInventoryIsMissing() {
    #expect(menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot()))
    #expect(!menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: []))))
}
