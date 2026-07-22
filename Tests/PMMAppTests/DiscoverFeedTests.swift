import Foundation
import Testing
@testable import PMMApp

@Test func discoverFeedGroupsEditorialNewPackagesAndRecommendations() throws {
    let feed = try JSONDecoder().decode(DiscoverFeed.self, from: Data("""
    {"content":[
      {"id":"editorial:one","type":"editorial","title":"Featured","primaryPackageID":"npm:typescript","relatedPackageIDs":["npm:typescript","brew:faker"]},
      {"id":"new","type":"newPackages","packageIDs":["brew:faker"]},
      {"id":"for-you","type":"personalizedRecommendations","candidatePackageIDs":["npm:typescript"]},
      {"id":"updated","type":"recentlyUpdated","packageIDs":["npm:typescript","brew:faker"]}
    ],"packages":{
      "brew:faker":{"id":"brew:faker","displayName":"Faker","agentSummary":"Fake data","manager":"homebrew","category":"data","homepage":"https://faker.readthedocs.io/"},
      "npm:typescript":{"id":"npm:typescript","displayName":"TypeScript","agentSummary":"Static checking","homepage":"https://www.typescriptlang.org/"}
    }}
    """.utf8))

    #expect(feed.editorial?.title == "Featured")
    #expect(feed.newPackages.map(\.displayName) == ["Faker"])
    #expect(feed.newPackages.first?.ecosystem == "Homebrew")
    #expect(feed.newPackages.first?.category == "data")
    #expect(feed.recommendations.map(\.displayName) == ["TypeScript"])
    #expect(feed.recentlyUpdated.map(\.displayName) == ["TypeScript", "Faker"])
    #expect(DiscoverFeedPage(legacy: feed).content.first?.relatedPackages?.map(\.id) == ["npm:typescript", "brew:faker"])
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

@Test @MainActor func discoverFeedStoreFallsBackToV1() async throws {
    let legacy = try JSONDecoder().decode(DiscoverFeed.self, from: Data("""
    {"content":[{"id":"new","type":"newPackages","packageIDs":["brew:faker"]}],"packages":{"brew:faker":{"id":"brew:faker","displayName":"Faker","agentSummary":"Fake data","manager":"homebrew","installURL":"pkgmgrmgr://install?package=brew%3Afaker"}}}
    """.utf8))
    let store = DiscoverFeedStore(
        pageLoader: { _ in throw URLError(.cannotDecodeContentData) },
        legacyLoader: { legacy }
    )

    await store.loadInitial()

    #expect(store.pages.map(\.pageID) == ["legacy"])
    #expect(store.pages.first?.content.first?.packages?.first?.id == "brew:faker")
    #expect(!store.initialLoadFailed)
}

@Test @MainActor func discoverFeedStoreRejectsPaginationCycle() async throws {
    let head = try decodePage("""
    {"pageID":"head","generatedAt":"2026-07-16T12:00:00Z","nextPageURL":"https://mxcl.dev/package-manager-manager/feed/v2.json","content":[]}
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
