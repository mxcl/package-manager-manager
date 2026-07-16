import Foundation

struct DiscoverFeed: Decodable {
    let content: [DiscoverFeedContent]
    let packages: [String: DiscoverFeedPackage]

    static let url = URL(string: "https://mxcl.dev/package-manager-manager/feed/v1.json")!

    static func load(from url: URL = url) async throws -> Self {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    var editorial: DiscoverFeedContent? { content.first { $0.type == "editorial" } }
    var newPackages: [DiscoverFeedPackage] { packages(for: content.first { $0.type == "newPackages" }?.packageIDs ?? []) }
    var recommendations: [DiscoverFeedPackage] { packages(for: content.first { $0.type == "personalizedRecommendations" }?.candidatePackageIDs ?? []) }

    private func packages(for ids: [String]) -> [DiscoverFeedPackage] {
        ids.compactMap { packages[$0] }
    }
}

struct DiscoverFeedContent: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String?
    let deck: String?
    let body: String?
    let primaryPackageID: String?
    let packageIDs: [String]?
    let candidatePackageIDs: [String]?
    let artwork: DiscoverFeedArtwork?

    var artworkURL: URL? {
        guard let path = artwork?.path else { return nil }
        return URL(string: path, relativeTo: URL(string: "https://mxcl.dev/package-manager-manager/")!)?.absoluteURL
    }
}

struct DiscoverFeedArtwork: Decodable {
    let path: String
}

struct DiscoverFeedPackage: Decodable, Identifiable {
    let id: String
    let displayName: String
    let agentSummary: String
    let category: String?
    let homepage: URL?
}
