import AppKit
import Foundation
import PMMCore
import Testing
@testable import PMMApp

@MainActor
private func discoverModel() -> MainWindowModel {
    MainWindowModel(
        userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
        store: PackageHostStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        bundledCatalog: [], usesPackageHostNotifications: false
    )
}

private func nativeDiscoverPage() throws -> DiscoverFeedPage {
    try JSONDecoder().decode(DiscoverFeedPage.self, from: Data("""
    {"pageID":"head","generatedAt":"2026-11-04","nextPageURL":"https://example.com/next.json","content":[
      {"id":"lead","type":"editorial","batchID":"new","title":"A long editorial heading that needs wrapping"},
      {"id":"new","type":"newPackages","batchID":"new","packages":[
        {"id":"brew:git","displayName":"git","agentSummary":"Version control","manager":"homebrew","installURL":"pkgmgrmgr://install?package=brew:git"}
      ]},
      {"id":"old","type":"editorial","batchID":"old","title":"An older story"},
      {"id":"unknown","type":"futureContent","batchID":"old"}
    ]}
    """.utf8))
}

@Test @MainActor func nativeDiscoverPreservesFeedOrderAndErrorStates() async throws {
    let page = try nativeDiscoverPage()
    let store = DiscoverFeedStore(pageLoader: { _ in page }, trendingLoader: { throw URLError(.notConnectedToInternet) })
    let model = discoverModel()
    let loading = DiscoverSection.make(store: store, model: model)
    guard case .status(_, true, nil) = loading.first?.items.first else {
        Issue.record("Initial content must have a spinner"); return
    }
    await store.loadInitial()
    await store.loadTrending()
    let sections = DiscoverSection.make(store: store, model: model)
    let editorials = sections.flatMap(\.items).compactMap { item -> String? in
        if case .editorial(let editorial) = item { return editorial.id }
        return nil
    }
    #expect(editorials == ["lead", "old"])
    #expect(sections.first?.items.count == 2)
    let trending = try #require(sections.first { $0.title == "New & Trending" })
    guard case .status(_, false, .trending) = trending.items.first else {
        Issue.record("Trending failure must offer a retry"); return
    }
    guard case .status(_, true, nil) = sections.last?.items.first else {
        Issue.record("Pagination must retain its loading footer"); return
    }
}

@Test @MainActor func nativeDiscoverPackageActionsUseExistingNavigation() async throws {
    let page = try nativeDiscoverPage()
    let store = DiscoverFeedStore(pageLoader: { _ in page })
    await store.loadInitial()
    let model = discoverModel()
    let package = ManagedPackage(manager: .homebrew, name: "git", installedVersion: "1", latestVersion: "2")
    model.apply(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: [package])))
    let controller = DiscoverController(model: model, store: store)
    _ = controller.view
    let item = controller.collectionView(controller.collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 1))
    let buttons = item.view.subviews.compactMap { $0 as? NSButton }
    let installed = try #require(buttons.first { $0.title == "Installed" })
    #expect(!installed.isEnabled)
    let details = try #require(buttons.first { $0.title == "Details" })
    details.performClick(nil)
    #expect(model.selectedPackage?.id == package.id)
    #expect(!model.showsDashboard)
    controller.stop()
}

@Test @MainActor func nativeDiscoverGridFitsNarrowAndWideWindows() throws {
    let page = try nativeDiscoverPage()
    let package = try #require(page.content[1].packages?.first)
    let section = DiscoverSection(items: Array(repeating: .package(package, nil), count: 5))
    for width: CGFloat in [240, 546, 856, 1400] {
        let size = section.size(at: 0, width: width)
        #expect(size.width > 0 && size.width <= width)
        let columns = max(1, Int((width + 12) / (size.width + 12)))
        #expect(CGFloat(columns) * size.width + CGFloat(columns - 1) * 12 <= width)
    }
}

@Test @MainActor func nativeDiscoverCardReuseRemovesStaleActions() throws {
    let page = try nativeDiscoverPage()
    let package = try #require(page.content[1].packages?.first)
    let card = DiscoverCard(frame: NSRect(x: 0, y: 0, width: 200, height: 240))
    var opened = false
    card.package(package, eyebrow: nil, installed: false, open: { opened = true }, install: {})
    card.status("Loading Discover", loading: true, retry: nil)
    #expect(card.subviews.compactMap { $0 as? NSButton }.isEmpty)
    #expect(!opened)
    #expect(card.subviews.contains { ($0 as? NSProgressIndicator)?.isHidden == false })
}
