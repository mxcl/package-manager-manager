import Combine
import Foundation

struct DiscoverFeed: Decodable, Sendable {
    let content: [DiscoverFeedContent]
    let packages: [String: DiscoverFeedPackage]

    static let url = URL(string: "https://mxcl.dev/package-manager-manager/feed/v1.json")!

    static func load(from url: URL = url) async throws -> Self {
        try await loadJSON(Self.self, from: url)
    }

    var editorial: DiscoverFeedContent? { content.first { $0.type == "editorial" } }
    var newPackages: [DiscoverFeedPackage] { packages(for: content.first { $0.type == "newPackages" }?.packageIDs ?? []) }
    var recommendations: [DiscoverFeedPackage] { packages(for: content.first { $0.type == "personalizedRecommendations" }?.candidatePackageIDs ?? []) }
    var recentlyUpdated: [DiscoverFeedPackage] { packages(for: content.first { $0.type == "recentlyUpdated" }?.packageIDs ?? []) }

    private func packages(for ids: [String]) -> [DiscoverFeedPackage] {
        ids.compactMap { packages[$0] }
    }
}

struct DiscoverFeedPage: Decodable, Identifiable, Sendable {
    let pageID: String
    let generatedAt: String
    let nextPageURL: URL?
    let content: [DiscoverFeedContent]

    var id: String { pageID }

    static let url = URL(string: "https://mxcl.dev/package-manager-manager/feed/v2.json")!

    static func load(from url: URL = url) async throws -> Self {
        try await loadJSON(Self.self, from: url)
    }

    init(legacy feed: DiscoverFeed) {
        pageID = "legacy"
        generatedAt = ""
        nextPageURL = nil
        content = feed.content.map { item in
            DiscoverFeedContent(
                id: item.id,
                type: item.type,
                batchID: "legacy",
                publishedAt: item.publishedAt,
                title: item.title,
                deck: item.deck,
                body: item.body,
                primaryPackageID: item.primaryPackageID,
                relatedPackageIDs: item.relatedPackageIDs,
                packageIDs: item.packageIDs,
                candidatePackageIDs: item.candidatePackageIDs,
                artwork: item.artwork,
                package: item.primaryPackageID.flatMap { feed.packages[$0] },
                relatedPackages: item.relatedPackageIDs.map { ids in ids.compactMap { feed.packages[$0] } },
                packages: (item.packageIDs ?? item.candidatePackageIDs).map { ids in ids.compactMap { feed.packages[$0] } }
            )
        }
    }
}

struct DiscoverFeedContent: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let batchID: String?
    let publishedAt: String?
    let title: String?
    let deck: String?
    let body: String?
    let primaryPackageID: String?
    let relatedPackageIDs: [String]?
    let packageIDs: [String]?
    let candidatePackageIDs: [String]?
    let artwork: DiscoverFeedArtwork?
    let package: DiscoverFeedPackage?
    let relatedPackages: [DiscoverFeedPackage]?
    let packages: [DiscoverFeedPackage]?

    var artworkURL: URL? {
        guard let path = artwork?.path else { return nil }
        return URL(string: path, relativeTo: URL(string: "https://mxcl.dev/package-manager-manager/")!)?.absoluteURL
    }
}

struct DiscoverFeedArtwork: Decodable, Sendable {
    let path: String
    let boxColors: BoxColors?

    struct BoxColors: Decodable, Sendable {
        let backgroundStart: String
        let backgroundEnd: String
        let foreground: String
    }
}

struct DiscoverFeedPackage: Decodable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let agentSummary: String
    let manager: String?
    let category: String?
    let homepage: URL?
    let installURL: URL?

    var ecosystem: String? {
        switch manager?.lowercased() {
        case "homebrew": "Homebrew"
        case "npm": "JavaScript"
        case .some(let manager): manager.capitalized
        case nil: nil
        }
    }
}

@MainActor
final class DiscoverFeedStore: ObservableObject {
    typealias PageLoader = @Sendable (URL) async throws -> DiscoverFeedPage
    typealias LegacyLoader = @Sendable () async throws -> DiscoverFeed

    @Published private(set) var pages: [DiscoverFeedPage] = []
    @Published private(set) var isLoadingInitial = false
    @Published private(set) var isLoadingNext = false
    @Published private(set) var initialLoadFailed = false
    @Published private(set) var nextPageLoadFailed = false

    private let pageLoader: PageLoader
    private let legacyLoader: LegacyLoader
    private var loadedURLs: Set<URL> = []

    init(
        pageLoader: @escaping PageLoader = { try await DiscoverFeedPage.load(from: $0) },
        legacyLoader: @escaping LegacyLoader = { try await DiscoverFeed.load() }
    ) {
        self.pageLoader = pageLoader
        self.legacyLoader = legacyLoader
    }

    var newestBatch: [DiscoverFeedContent] {
        guard let first = pages.first?.content.first else { return [] }
        return pages.first?.content.prefix { $0.batchID == first.batchID }.map { $0 } ?? []
    }

    var olderContent: [DiscoverFeedContent] {
        let all = pages.flatMap(\.content)
        return Array(all.dropFirst(newestBatch.count))
    }

    var hasNextPage: Bool { pages.last?.nextPageURL != nil }

    func loadInitial() async {
        guard pages.isEmpty, !isLoadingInitial else { return }
        isLoadingInitial = true
        initialLoadFailed = false
        defer { isLoadingInitial = false }
        do {
            let page = try await pageLoader(DiscoverFeedPage.url)
            try append(page, loadedFrom: DiscoverFeedPage.url)
        } catch is CancellationError {
        } catch {
            do {
                pages = [DiscoverFeedPage(legacy: try await legacyLoader())]
            } catch is CancellationError {
            } catch {
                initialLoadFailed = true
            }
        }
    }

    func loadNext() async {
        guard let url = pages.last?.nextPageURL, !isLoadingNext else { return }
        guard !loadedURLs.contains(url) else {
            nextPageLoadFailed = true
            return
        }
        isLoadingNext = true
        nextPageLoadFailed = false
        defer { isLoadingNext = false }
        do {
            try append(try await pageLoader(url), loadedFrom: url)
        } catch is CancellationError {
        } catch {
            nextPageLoadFailed = true
        }
    }

    private func append(_ page: DiscoverFeedPage, loadedFrom url: URL) throws {
        let existingPageIDs = Set(pages.map(\.pageID))
        let existingContentIDs = Set(pages.flatMap(\.content).map(\.id))
        guard !existingPageIDs.contains(page.pageID), existingContentIDs.isDisjoint(with: page.content.map(\.id)) else {
            throw URLError(.cannotParseResponse)
        }
        pages.append(page)
        loadedURLs.insert(url)
    }
}

private func loadJSON<Value: Decodable>(_ type: Value.Type, from url: URL) async throws -> Value {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
        throw URLError(.badServerResponse)
    }
    try Task.checkCancellation()
    return try JSONDecoder().decode(type, from: data)
}
