import AppKit
import Combine
import SwiftUI

struct NativeDiscover: NSViewControllerRepresentable {
    let model: MainWindowModel
    let store: DiscoverFeedStore
    @Binding var scrollOffset: CGFloat

    func makeNSViewController(context: Context) -> DiscoverController {
        DiscoverController(model: model, store: store, scrollOffset: scrollOffset)
    }

    func updateNSViewController(_ controller: DiscoverController, context: Context) {
        controller.saveScrollOffset = { scrollOffset = $0 }
    }

    static func dismantleNSViewController(_ controller: DiscoverController, coordinator: ()) {
        controller.stop()
    }
}

/// Native, recycled cards. Inventory changes only update install buttons.
/// Neither command output nor selection changes rebuild the feed.
@MainActor
final class DiscoverController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let collection = NSCollectionView()
    let scroll = NSScrollView()
    private let model: MainWindowModel
    private let store: DiscoverFeedStore
    private var sections: [DiscoverSection] = []
    private var observations: [AnyCancellable] = []
    private var initialTask: Task<Void, Never>?
    private var trendingTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var refreshScheduled = false
    private var restoringScroll = true
    private var reconciling = false
    private var savedOffset: CGFloat
    var saveScrollOffset: ((CGFloat) -> Void)?
    private static let itemID = NSUserInterfaceItemIdentifier("discover-card")
    private static let headerID = NSUserInterfaceItemIdentifier("discover-heading")

    init(model: MainWindowModel, store: DiscoverFeedStore, scrollOffset: CGFloat = 0) {
        self.model = model
        self.store = store
        self.savedOffset = scrollOffset
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let layout = DiscoverFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 0, left: 28, bottom: 24, right: 28)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.isSelectable = false
        collection.register(DiscoverCollectionItem.self, forItemWithIdentifier: Self.itemID)
        collection.register(DiscoverHeading.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Self.headerID)
        collection.setAccessibilityIdentifier("discover-feed")
        collection.setAccessibilityLabel("Discover")
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        view = scroll
        observations = [
            store.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
            Publishers.MergeMany([
                uiChange(model.$dashboardBlogEntries), uiChange(model.$dashboardBlogEntriesAreLoading),
                uiChange(model.$dashboardBlogLoadFailed),
            ]).sink { [weak self] in self?.scheduleRefresh() },
            model.$packages.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateInstalledButtons() }
            },
            NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
                .sink { [weak self] _ in self?.didScroll() },
        ]
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        initialTask = Task { [store] in await store.loadInitial() }
        trendingTask = Task { [store] in await store.loadTrending() }
        restoreScrollIfReady()
    }

    func stop() {
        initialTask?.cancel()
        trendingTask?.cancel()
        nextTask?.cancel()
        observations.removeAll()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        let offset = restoringScroll ? savedOffset : scroll.contentView.bounds.minY
        let next = DiscoverSection.make(store: store, model: model)
        guard next != sections else { return }
        reconciling = true
        defer { reconciling = false }
        let previous = sections
        sections = next
        if previous.count == next.count {
            collection.reloadSections(IndexSet(next.indices.filter { next[$0] != previous[$0] }))
        } else {
            collection.reloadData()
        }
        collection.layoutSubtreeIfNeeded()
        if restoringScroll { restoreScrollIfReady() }
        else { scroll.contentView.scroll(to: NSPoint(x: 0, y: offset)); scroll.reflectScrolledClipView(scroll.contentView) }
        loadNextIfNeeded()
    }

    private func restoreScrollIfReady() {
        guard restoringScroll, !store.pages.isEmpty, view.window != nil else { return }
        collection.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: savedOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        restoringScroll = false
    }

    private func didScroll() {
        guard !restoringScroll, !reconciling else { return }
        savedOffset = max(0, scroll.contentView.bounds.minY)
        let offset = savedOffset
        Task { @MainActor [weak self] in self?.saveScrollOffset?(offset) }
        loadNextIfNeeded()
    }

    func loadNextIfNeeded() {
        guard view.window != nil, !restoringScroll, store.hasNextPage,
              !store.isLoadingNext, !store.nextPageLoadFailed, nextTask == nil,
              scroll.contentView.bounds.maxY + 240 >= collection.bounds.height else { return }
        nextTask = Task { [weak self, store] in
            await store.loadNext()
            self?.nextTask = nil
        }
    }

    private func updateInstalledButtons() {
        for item in collection.visibleItems() {
            guard let item = item as? DiscoverCollectionItem, let package = item.package else { continue }
            item.card.setInstalled(model.isDiscoverPackageInstalled(package))
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! DiscoverCollectionItem
        let content = sections[indexPath.section].items[indexPath.item]
        item.package = nil
        switch content {
        case .editorial(let editorial):
            item.card.editorial(editorial) { [weak self] in self?.read(editorial) }
        case .sponsor:
            item.card.sponsor()
        case .package(let package, let eyebrow):
            item.package = package
            item.card.package(package, eyebrow: eyebrow, installed: model.isDiscoverPackageInstalled(package),
                              open: { [weak model] in model?.openDiscoverPackage(package) },
                              install: { [weak model] in model?.openDiscoverPackage(package, installing: true) })
        case .blog(let post): item.card.blog(post)
        case .status(let text, let loading, let retry):
            item.card.status(text, loading: loading, retry: retry.map { action in
                { [weak self] in self?.retry(action) }
            })
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.headerID, for: indexPath) as! DiscoverHeading
        let section = sections[indexPath.section]
        header.configure(title: section.title, subtitle: section.subtitle, link: section.link, large: indexPath.section == 0)
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        sections[indexPath.section].size(at: indexPath.item, width: max(1, scroll.contentSize.width - 56))
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        let value = sections[section]
        return NSSize(width: scroll.contentSize.width, height: value.title.isEmpty ? 0 : (section == 0 ? 72 : 40) + (value.subtitle == nil ? 0 : 38))
    }

    private func retry(_ action: DiscoverRetry) {
        switch action {
        case .initial: initialTask = Task { [store] in await store.loadInitial() }
        case .trending: trendingTask = Task { [store] in await store.loadTrending() }
        case .blog: model.retryDashboardBlog()
        case .next:
            guard nextTask == nil else { return }
            nextTask = Task { [weak self, store] in await store.loadNext(); self?.nextTask = nil }
        }
    }

    private func read(_ editorial: DiscoverFeedContent) {
        let reader = DashboardDiscoverEditorialReader(
            editorial: editorial, package: editorial.package,
            isPackageInstalled: model.isDiscoverPackageInstalled,
            openPackage: { [weak model] in model?.openDiscoverPackage($0) },
            installPackage: { [weak model] in model?.openDiscoverPackage($0, installing: true) }
        )
        let host = NSHostingController(rootView: reader)
        host.rootView.close = { [weak self, weak host] in
            if let host { self?.dismiss(host) }
        }
        presentAsSheet(host)
    }
}

private final class DiscoverFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

private final class DiscoverCollectionItem: NSCollectionViewItem {
    let card = DiscoverCard()
    var package: DiscoverFeedPackage?
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.reset(); package = nil }
}

enum DiscoverRetry: Equatable { case initial, trending, blog, next }
enum DiscoverItem: Equatable {
    case editorial(DiscoverFeedContent), sponsor, package(DiscoverFeedPackage, String?), blog(DashboardBlogEntry)
    case status(String, Bool, DiscoverRetry?)
}

struct DiscoverSection: Equatable {
    enum Arrangement: Equatable { case lead, blog, grid, single }
    var title = ""
    var subtitle: String?
    var link: URL?
    var arrangement: Arrangement = .grid
    var items: [DiscoverItem]

    func size(at index: Int, width: CGFloat) -> NSSize {
        switch arrangement {
        case .lead:
            let wide = width >= 726 && items.count == 2
            return NSSize(width: wide ? (index == 0 ? width - 334 : 310) : width, height: 360)
        case .blog:
            if width >= 856 {
                let cardWidth = index == 3 ? 220 : floor((width - 256) / 3)
                return NSSize(width: cardWidth, height: 270)
            }
            let columns = max(1, min(3, Int((width + 12) / 212)))
            return NSSize(width: index == 3 ? width : floor((width - CGFloat(columns - 1) * 12) / CGFloat(columns)), height: 270)
        case .single: return NSSize(width: width, height: 180)
        case .grid:
            let columns = max(1, Int((width + 12) / 192))
            let cardWidth = floor((width - CGFloat(columns - 1) * 12) / CGFloat(columns))
            let height = items.map { item -> CGFloat in
                guard case .package(let package, _) = item else { return 180 }
                return max(186, 132 + discoverTextHeight(package.displayName, width: cardWidth - 36, size: 13, weight: .semibold)
                           + discoverTextHeight(package.agentSummary, width: cardWidth - 36, size: 11))
            }.max() ?? 186
            return NSSize(width: cardWidth, height: height)
        }
    }

    @MainActor static func make(store: DiscoverFeedStore, model: MainWindowModel) -> [Self] {
        guard !store.pages.isEmpty else {
            return [Self(title: "Discover", arrangement: .single, items: [
                .status(store.initialLoadFailed ? "Discover is unavailable" : "Loading Discover", !store.initialLoadFailed, store.initialLoadFailed ? .initial : nil)
            ])]
        }
        let lead = store.newestBatch.first { $0.type == "editorial" }
        var result = [Self(title: "Discover", arrangement: .lead, items: lead.map { [.editorial($0), .sponsor] } ?? [.sponsor])]
        func append(_ item: DiscoverFeedContent) {
            if item.type == "editorial" {
                result.append(Self(arrangement: .lead, items: [.editorial(item)]))
            } else if ["newPackages", "personalizedRecommendations", "recentlyUpdated", "installPack"].contains(item.type) {
                let packages = item.packages ?? []
                let defaults = ["newPackages": "New Packages", "personalizedRecommendations": "For You", "recentlyUpdated": "Recently Updated", "installPack": "Install Pack"]
                let title = dashboardDiscoverSectionTitle(item.title ?? defaults[item.type]!, packages: packages)
                result.append(Self(title: title, subtitle: item.deck, items: (item.type == "installPack" ? packages : Array(packages.prefix(5))).map { .package($0, nil) }))
            }
        }
        store.newestBatch.filter { $0.id != lead?.id }.forEach(append)
        var blog: [DiscoverItem]
        if model.dashboardBlogEntriesAreLoading {
            blog = Array(repeating: .status("Loading blog posts", true, nil), count: 3)
        } else if model.dashboardBlogPosts.isEmpty {
            blog = [.status(model.dashboardBlogLoadFailed ? "Blog posts couldn’t be loaded" : "No blog posts yet", false, model.dashboardBlogLoadFailed ? .blog : nil)]
        } else { blog = model.dashboardBlogPosts.prefix(3).map { .blog($0) } }
        let spotlight = (store.newestBatch + store.olderContent).first { $0.type == "personalizedRecommendations" }?.packages?.first
        if let spotlight {
            while blog.count < 3 { blog.append(.status("", false, nil)) }
            blog.append(.package(spotlight, "FOR YOU"))
        }
        result.append(Self(title: "Blog & Updates", link: URL(string: "https://mxcl.dev/package-manager-manager/blog/"), arrangement: .blog, items: blog))
        var trending = Self(title: "New & Trending", link: URL(string: "https://pkg.so/new-and-trending/"), items: [])
        if let feed = store.trendingFeed, !feed.packages.isEmpty {
            trending.items = feed.packages.map { .package($0, nil) }
        } else {
            trending.arrangement = .single
            trending.items = [.status(store.trendingFeed != nil ? "No new or trending packages right now" : store.trendingLoadFailed ? "New & Trending is unavailable" : "Loading New & Trending", store.trendingFeed == nil && !store.trendingLoadFailed, store.trendingLoadFailed ? .trending : nil)]
        }
        result.append(trending)
        store.olderContent.forEach(append)
        if store.hasNextPage {
            result.append(Self(arrangement: .single, items: [.status(store.nextPageLoadFailed ? "Older stories couldn’t be loaded" : "Loading more", !store.nextPageLoadFailed, store.nextPageLoadFailed ? .next : nil)]))
        }
        return result
    }
}
