import Foundation
import PMMCore
import Testing
@testable import PMMMenuBar

@Test func menuStateShowsLoadingBeforeInventoryExists() {
    let state = MenuBarMenuState()

    #expect(state.rows == [.loading])
}

@Test func menuStateShowsEmptyOutdatedInventory() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .homebrew, name: "git", installedVersion: "2.0.0", latestVersion: "2.0.0")
    ]))

    #expect(state.rows == [.empty])
}

@Test func menuStateShowsSortedOutdatedPackageRows() {
    let state = MenuBarMenuState(inventory: PackageInventory(packages: [
        ManagedPackage(manager: .npm, name: "zeta", installedVersion: "1.0.0", latestVersion: "2.0.0"),
        ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1.0.0", latestVersion: "1.2.0"),
        ManagedPackage(manager: .npm, name: "alpha", installedVersion: "1.0.0", latestVersion: "3.0.0"),
    ]))

    #expect(state.rows == [
        .package(MenuBarPackageRow(managerTitle: "Homebrew", name: "git", installedVersion: "1.0.0", latestVersion: "1.2.0")),
        .package(MenuBarPackageRow(managerTitle: "npm", name: "alpha", installedVersion: "1.0.0", latestVersion: "3.0.0")),
        .package(MenuBarPackageRow(managerTitle: "npm", name: "zeta", installedVersion: "1.0.0", latestVersion: "2.0.0")),
    ])
}
