import Foundation
import Testing
@testable import PMMApp

@Test func discoverFeedUsesCanonicalPkgSoEndpoints() throws {
    #expect(DiscoverFeedPage.url == URL(string: "https://pkg.so/discover/feed/v2.json"))

    let page = try decodePage("""
    {"pageID":"head","generatedAt":"2026-08-09T12:00:00Z","nextPageURL":null,"content":[
      {"id":"editorial:one","type":"editorial","artwork":{"path":"feed/assets/editorial.png","boxColors":{"backgroundStart":"#000000","backgroundEnd":"#111111","foreground":"#ffffff"}}}
    ]}
    """)

    #expect(page.content.first?.artworkURL == URL(string: "https://pkg.so/discover/feed/assets/editorial.png"))
}

@Test func discoverFeedV2DecodesSelfContainedBlocks() throws {
    let page = try decodePage("""
    {"pageID":"head","generatedAt":"2026-07-16T12:00:00Z","nextPageURL":"https://example.com/older.json","content":[
      {"id":"editorial:one","type":"editorial","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","title":"Featured","package":{"id":"npm:typescript","displayName":"TypeScript","agentSummary":"Static checking","manager":"npm","installURL":"pkgmgrmgr://install?package=npm%3Atypescript"},"relatedPackages":[{"id":"npm:typescript","displayName":"TypeScript","agentSummary":"Static checking","manager":"npm","installURL":"pkgmgrmgr://install?package=npm%3Atypescript"},{"id":"brew:faker","displayName":"Faker","agentSummary":"Fake data","manager":"homebrew","installURL":"pkgmgrmgr://install?package=brew%3Afaker"}]},
      {"id":"new:one","type":"newPackages","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","packages":[{"id":"brew:faker","displayName":"Faker","agentSummary":"Fake data","manager":"homebrew","homepage":"https://example.com","installURL":"pkgmgrmgr://install?package=brew%3Afaker"}]},
      {"id":"pack:one","type":"installPack","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","title":"Fixture Pack","packages":[{"id":"brew:faker","displayName":"Faker","agentSummary":"Fake data","manager":"homebrew","homepage":"https://example.com","installURL":"pkgmgrmgr://install?package=brew%3Afaker"}]}
    ]}
    """)

    #expect(page.pageID == "head")
    #expect(page.nextPageURL == URL(string: "https://example.com/older.json"))
    #expect(page.content.first?.package?.installURL?.scheme == "pkgmgrmgr")
    #expect(page.content.first?.relatedPackages?.map(\.id) == ["npm:typescript", "brew:faker"])
    #expect(page.content.last?.type == "installPack")
    #expect(page.content.last?.title == "Fixture Pack")
    #expect(page.content.last?.packages?.first?.ecosystem == "Homebrew")
}

@Test func discoverSectionTitlesVaryBySharedPackageCategory() {
    let mediaPackages = [
        discoverPackage("brew:ffmpeg", category: "media"),
        discoverPackage("brew:imagemagick", category: "media"),
    ]

    #expect(dashboardDiscoverSectionTitle("For You", packages: mediaPackages) == "For You in Media")
    #expect(dashboardDiscoverSectionTitle("New Packages", packages: [discoverPackage("brew:nmap", category: "networking")]) == "New Packages in Networking")
}

@Test func discoverSectionTitlesKeepCustomAndMixedCategoryHeadings() {
    let mixedPackages = [
        discoverPackage("brew:ffmpeg", category: "media"),
        discoverPackage("brew:nmap", category: "networking"),
    ]

    #expect(dashboardDiscoverSectionTitle("For You", packages: mixedPackages) == "For You")
    #expect(dashboardDiscoverSectionTitle("Staff Picks", packages: [discoverPackage("brew:ffmpeg", category: "media")]) == "Staff Picks")
}

@Test @MainActor func discoverFeedStoreLoadsPagesInOrder() async throws {
    let head = try decodePage("""
    {"pageID":"head","generatedAt":"2026-07-16T12:00:00Z","nextPageURL":"https://example.com/older.json","content":[
      {"id":"editorial:new","type":"editorial","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","title":"Newest"},
      {"id":"recommendations:new","type":"personalizedRecommendations","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","packages":[]},
      {"id":"new:new","type":"newPackages","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","packages":[]},
      {"id":"updated:new","type":"recentlyUpdated","batchID":"batch-2","publishedAt":"2026-07-16T12:00:00Z","packages":[]},
      {"id":"recommendations:previous","type":"personalizedRecommendations","batchID":"batch-1","publishedAt":"2026-07-13T12:00:00Z","packages":[]}
    ]}
    """)
    let older = try decodePage("""
    {"pageID":"older","generatedAt":"2026-07-10T12:00:00Z","nextPageURL":null,"content":[
      {"id":"editorial:old","type":"editorial","batchID":"batch-0","publishedAt":"2026-07-10T12:00:00Z","title":"Oldest"}
    ]}
    """)
    let store = DiscoverFeedStore(pageLoader: { url in
        url == DiscoverFeedPage.url ? head : older
    })

    await store.loadInitial()
    #expect(store.newestBatch.map(\.id) == ["editorial:new", "recommendations:new", "new:new", "updated:new"])
    #expect(store.olderContent.isEmpty)
    #expect(store.hasNextPage)

    await store.loadNext()
    #expect(store.pages.map(\.pageID) == ["head", "older"])
    #expect(store.olderContent.map(\.id) == ["editorial:old"])
    #expect(!store.hasNextPage)
}

@Test @MainActor func discoverFeedStoreReportsInitialLoadFailureWithoutLegacyFallback() async throws {
    let store = DiscoverFeedStore(pageLoader: { _ in throw URLError(.cannotDecodeContentData) })

    await store.loadInitial()

    #expect(store.pages.isEmpty)
    #expect(store.initialLoadFailed)
}

@Test @MainActor func discoverFeedStoreRejectsPaginationCycle() async throws {
    let head = try decodePage("""
    {"pageID":"head","generatedAt":"2026-07-16T12:00:00Z","nextPageURL":"https://pkg.so/discover/feed/v2.json","content":[]}
    """)
    let store = DiscoverFeedStore(pageLoader: { _ in head })

    await store.loadInitial()
    await store.loadNext()

    #expect(store.pages.count == 1)
    #expect(store.nextPageLoadFailed)
}

@Test @MainActor func discoverFeedStoreHidesRepeatedSectionsButKeepsDifferentlyNamedShelves() async throws {
    let packageJSON = "{\"id\":\"brew:ffmpeg\",\"displayName\":\"ffmpeg\",\"agentSummary\":\"Media tools\",\"manager\":\"homebrew\"}"
    let head = try decodePage("""
    {"pageID":"head","generatedAt":"2026-07-20T12:00:00Z","nextPageURL":"https://example.com/older.json","content":[
      {"id":"editorial:new","type":"editorial","batchID":"batch-new","publishedAt":"2026-07-20T12:00:00Z","title":"Newest"},
      {"id":"for-you:new","type":"personalizedRecommendations","batchID":"shelves-new","publishedAt":"2026-07-20T12:00:00Z","title":"For You","packages":[\(packageJSON)]}
    ]}
    """)
    let older = try decodePage("""
    {"pageID":"older","generatedAt":"2026-07-19T12:00:00Z","nextPageURL":null,"content":[
      {"id":"editorial:duplicate","type":"editorial","batchID":"shelves-old","publishedAt":"2026-07-19T12:00:00Z","title":"Newest"},
      {"id":"for-you:old","type":"personalizedRecommendations","batchID":"shelves-old","publishedAt":"2026-07-19T12:00:00Z","title":"For You","packages":[\(packageJSON)]},
      {"id":"for-you:media","type":"personalizedRecommendations","batchID":"shelves-old","publishedAt":"2026-07-19T12:00:00Z","title":"For You in Media","packages":[\(packageJSON)]}
    ]}
    """)
    let store = DiscoverFeedStore(pageLoader: { url in
        url == DiscoverFeedPage.url ? head : older
    })

    await store.loadInitial()
    await store.loadNext()

    #expect(store.newestBatch.map(\.id) == ["editorial:new"])
    #expect(store.olderContent.map(\.id) == ["for-you:new", "for-you:media"])
    #expect(store.olderContent.flatMap { $0.packages ?? [] }.map(\.id) == ["brew:ffmpeg", "brew:ffmpeg"])
}

@Test @MainActor func discoverFeedStoreKeepsLeadEditorialWhenShelfBatchDiffers() async throws {
    let head = try decodePage("""
    {"pageID":"head","generatedAt":"2026-07-22T12:00:00Z","nextPageURL":null,"content":[
      {"id":"editorial:new","type":"editorial","batchID":"editorial-batch","title":"Newest"},
      {"id":"new:new","type":"newPackages","batchID":"shelf-batch","title":"New Packages","packages":[]}
    ]}
    """)
    let store = DiscoverFeedStore(pageLoader: { _ in head })

    await store.loadInitial()

    #expect(store.newestBatch.map(\.id) == ["editorial:new"])
    #expect(store.olderContent.map(\.id) == ["new:new"])
}

private func decodePage(_ json: String) throws -> DiscoverFeedPage {
    try JSONDecoder().decode(DiscoverFeedPage.self, from: Data(json.utf8))
}

private func discoverPackage(_ id: String, category: String?) -> DiscoverFeedPackage {
    DiscoverFeedPackage(
        id: id,
        displayName: id,
        agentSummary: "",
        manager: nil,
        category: category,
        homepage: nil,
        installURL: nil
    )
}

@Test func discoverTrendingDecodesPkgSoAndMapsCasksForNavigation() throws {
    let feed = try JSONDecoder().decode(DiscoverTrendingFeed.self, from: Data("""
    {"trending":[
      {"packageKey":"brew:python@3.15","displayName":"Python","summary":"Language","homepage":"https://python.org"},
      {"packageKey":"cask:owner/tap/tool","displayName":"Tool","summary":"Utility","homepage":null}
    ],"recentlyDiscovered":[],"independentTaps":[]}
    """.utf8))

    #expect(feed.packages.map(\.id) == ["brew:python@3.15", "brew:cask:owner/tap/tool"])
    let cask = try #require(feed.packages.last)
    #expect(MainWindowPackageURLRequest(identifier: cask.id)?.name == "cask/owner/tap/tool")
    let url = try #require(cask.installURL)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == cask.id)
}

@Test func discoverTrendingFallsBackToRecentAndDeduplicates() throws {
    let entry = """
    {"packageKey":"brew:new","displayName":"New","summary":"New to the catalog"}
    """
    let feed = try JSONDecoder().decode(DiscoverTrendingFeed.self, from: Data("""
    {"trending":[],"recentlyDiscovered":[\(entry),\(entry)]}
    """.utf8))
    #expect(feed.packages.map(\.id) == ["brew:new"])
}

@Test @MainActor func discoverTrendingLoadingIsIndependentOfEditorials() async {
    let store = DiscoverFeedStore(trendingLoader: {
        throw URLError(.notConnectedToInternet)
    })
    await store.loadTrending()
    #expect(store.trendingLoadFailed)
    #expect(!store.isLoadingTrending)
    #expect(store.pages.isEmpty)
    #expect(!store.initialLoadFailed)

    // A separate successful loader verifies that even an empty response finishes loading.
    let emptyStore = DiscoverFeedStore(trendingLoader: {
        DiscoverTrendingFeed(trending: [], recentlyDiscovered: [])
    })
    await emptyStore.loadTrending()
    #expect(emptyStore.trendingFeed != nil)
    #expect(!emptyStore.trendingLoadFailed)
}

@Test @MainActor func discoverBlogUsesPkgSoEditorialLinksAndArtwork() async throws {
    let page = try decodePage("""
    {"pageID":"head","generatedAt":"2026-10-30","nextPageURL":null,"content":[
      {"id":"shelf","type":"newPackages","title":"Packages"},
      {"id":"editorial:2026-10-28:coding-agents","type":"editorial","title":"Coding agents","deck":"Local tools","publishedAt":"2026-10-28T12:00:00Z","artwork":{"path":"feed/assets/agents.png"}},
      {"id":"editorial:2026-10-29:newer","type":"editorial","title":"Newer","publishedAt":"2026-10-29T12:00:00Z"}
    ]}
    """)
    let store = DiscoverFeedStore(pageLoader: { _ in page })
    await store.loadInitial()
    #expect(store.blogPosts.map(\.title) == ["Newer", "Coding agents"])
    let post = try #require(store.blogPosts.last)
    #expect(post.url.absoluteString == "https://pkg.so/blog/2026-10-28/coding-agents/")
    #expect(post.imageURL.absoluteString == "https://pkg.so/discover/feed/assets/agents.png")
    #expect(post.subtitle == "Local tools")
    #expect(post.publishedAt == "2026-10-28")
}
