import Foundation

public struct PackageDatabase: Sendable {
    public static let url = URL(string: "https://automicvault.com/db.json")!

    private let formulas: [String: PackageMetadata]
    private let casks: [String: PackageMetadata]
    private let npms: [String: PackageMetadata]

    public init(formulas: [String: PackageMetadata] = [:], casks: [String: PackageMetadata] = [:], npms: [String: PackageMetadata] = [:]) {
        self.formulas = formulas
        self.casks = casks
        self.npms = npms
    }

    public static func load(from url: URL = Self.url) async -> PackageDatabase {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try decode(data)
        } catch {
            return PackageDatabase()
        }
    }

    public static func decode(_ data: Data) throws -> PackageDatabase {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sources = root?["sources"] as? [String: Any]
        let db = sources?["db"] as? [String: Any]
        return PackageDatabase(
            formulas: decodeMetadataMap(db?["formulas"]),
            casks: decodeMetadataMap(db?["casks"]),
            npms: decodeMetadataMap(db?["npms"])
        )
    }

    public func metadata(for manager: PackageManagerKind, name: String) -> PackageMetadata? {
        switch manager {
        case .homebrew:
            return formulas[name] ?? casks[name]
        case .npm, .npx:
            return npms[name]
        }
    }

    private static func decodeMetadataMap(_ value: Any?) -> [String: PackageMetadata] {
        guard let map = value as? [String: Any] else { return [:] }
        return map.reduce(into: [:]) { result, pair in
            guard let raw = pair.value as? [String: Any] else { return }
            result[pair.key] = PackageMetadata(
                summary: raw["summary"] as? String,
                category: raw["category"] as? String,
                homepage: raw["homepage"] as? String,
                version: raw["version"] as? String
            )
        }
    }
}
