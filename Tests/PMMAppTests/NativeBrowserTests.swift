import AppKit
import Foundation
import PMMCore
import Testing
@testable import PMMApp

@MainActor
private func browserFixture(_ packages: [ManagedPackage]) -> MainWindowModel {
    let model = MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        bundledCatalog: [], usesPackageHostNotifications: false
    )
    model.apply(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: packages)))
    return model
}

@MainActor
@Test func nativeTableSynchronizesSelectionAndPreservesItAcrossMetadataChanges() {
    let first = ManagedPackage(manager: .homebrew, name: "alpha", installedVersion: "1", latestVersion: "2")
    let second = ManagedPackage(manager: .homebrew, name: "beta", installedVersion: "1", latestVersion: "2")
    let model = browserFixture([first, second])
    model.selectSection(.outdated)
    let controller = PackageListController(model: model)
    _ = controller.view
    #expect(controller.table.numberOfRows == 2)
    #expect(controller.table.allowsMultipleSelection)
    controller.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    #expect(model.selectedPackageIDs == [first.id, second.id])
    #expect(model.hasMultipleSelectedPackages)

    let added = ManagedPackage(manager: .homebrew, name: "gamma", installedVersion: "1", latestVersion: "3")
    model.apply(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: [first, second, added])))
    controller.refresh()
    #expect(controller.table.numberOfRows == 3)
    #expect(controller.table.selectedRowIndexes.count == 2)
    #expect(model.selectedPackageIDs == [first.id, second.id])

    model.selectSection(.installed)
    controller.refresh()
    #expect(!controller.table.allowsMultipleSelection)
    #expect(controller.table.selectedRowIndexes.isEmpty)
}

@MainActor
@Test func nativeTableFollowsDeepLinkSelectionAndHandlesRemovedRows() {
    let package = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    let model = browserFixture([package])
    model.selectSection(.installed)
    let controller = PackageListController(model: model)
    _ = controller.view
    model.select(package)
    controller.refresh()
    #expect(controller.table.selectedRow == 0)
    model.apply(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: [])))
    controller.refresh()
    #expect(controller.table.numberOfRows == 0)
    #expect(controller.table.selectedRow == -1)
    #expect(model.selectedPackage == nil)
}

@MainActor
@Test func searchPublishesOnlyTheNewestRequestAndPreservesExactMatchRanking() async {
    let packages = ["git", "git-lfs", "ripgrep"].map {
        ManagedPackage(manager: .homebrew, name: $0, installedVersion: "1", latestVersion: "1")
    }
    let model = browserFixture(packages)
    model.searchText = "ripgrep"
    model.searchText = "git"
    #expect(model.searchIsLoading)
    await model.waitForSearch()
    #expect(!model.searchIsLoading)
    #expect(model.displayedPackages.map(\.displayName) == ["git", "git-lfs"])
    model.searchText = "ripgrep"
    model.searchText = ""
    await model.waitForSearch()
    #expect(model.activeSidebarSection == .home)
    #expect(!model.searchIsLoading)
}

@MainActor
@Test func explicitInventoryCannotBeOverwrittenByAnOlderPendingDiskLoad() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PackageHostStore(directory: directory)
    let old = ManagedPackage(manager: .homebrew, name: "old", installedVersion: "1", latestVersion: "1")
    let fresh = ManagedPackage(manager: .homebrew, name: "fresh", installedVersion: "1", latestVersion: "1")
    try store.save(PackageHostSnapshot(inventory: PackageInventory(packages: [old])))
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, store: store,
                                bundledCatalog: [], usesPackageHostNotifications: false)
    model.apply(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: [fresh])))
    await model.waitForHostSync()
    #expect(model.packages == [fresh])
}

@MainActor
@Test func nativeSidebarRestoresSelectionAfterSearch() async {
    let model = browserFixture([])
    model.selectSection(.installed)
    let controller = SidebarController(model: model)
    _ = controller.view
    let installedRow = controller.outline.selectedRow
    #expect(installedRow >= 0)
    controller.search.stringValue = "git"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    await model.waitForSearch()
    controller.refresh()
    #expect(model.activeSidebarSection == .search)
    #expect(controller.outline.selectedRow == 0)
    controller.search.stringValue = ""
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    controller.refresh()
    #expect(model.activeSidebarSection == .installed)
    #expect(controller.outline.selectedRow == installedRow)
}

@MainActor
@Test func nativeTableKeepsExistingCellsForUnrelatedStateChanges() {
    let model = browserFixture([ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "1")])
    model.selectSection(.installed)
    let controller = PackageListController(model: model)
    _ = controller.view
    let cell = controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
    model.selectedLinkTab = .repo
    controller.refresh()
    #expect(cell != nil)
    #expect(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: false) === cell)
}
