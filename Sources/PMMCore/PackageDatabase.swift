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
        (try? await fetch(from: url)) ?? PackageDatabase()
    }

    public static func fetch(from url: URL = Self.url) async throws -> PackageDatabase {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decode(data)
    }

    public static func cached(from url: URL = Self.url, cache: URLCache = .shared) -> PackageDatabase? {
        let request = URLRequest(url: url)
        guard let data = cache.cachedResponse(for: request)?.data else { return nil }
        return try? decode(data)
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

    public var catalogPackages: [ManagedPackage] {
        let packages = (
            managedPackages(for: .homebrew, metadata: formulas) +
            managedPackages(for: .homebrew, metadata: casks) +
            managedPackages(for: .npm, metadata: npms)
        )
        return Dictionary(grouping: packages, by: \.id).compactMap { $0.value.first }
            .sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public func metadata(for manager: PackageManagerKind, name: String) -> PackageMetadata? {
        switch manager {
        case .cargoInstall:
            return nil
        case .homebrew:
            return formulas[name] ?? casks[name]
        case .npm, .npx:
            return npms[name]
        case .uv, .uvx:
            return nil
        }
    }

    private static func decodeMetadataMap(_ value: Any?) -> [String: PackageMetadata] {
        guard let map = value as? [String: Any] else { return [:] }
        return map.reduce(into: [:]) { result, pair in
            guard let raw = pair.value as? [String: Any] else { return }
            result[pair.key] = PackageMetadata(
                summary: nil,
                category: raw["category"] as? String,
                homepage: nil,
                docs: nil,
                repo: nil,
                version: nil,
                lastUpdatedAt: raw["last_updated_at"] as? String,
                pulseKind: raw["pulse_kind"] as? String
            )
        }
    }

    private func managedPackages(for manager: PackageManagerKind, metadata: [String: PackageMetadata]) -> [ManagedPackage] {
        metadata.map { name, metadata in
            ManagedPackage(
                manager: manager,
                name: name,
                installedVersion: nil,
                latestVersion: nil,
                summary: nil,
                category: metadata.category,
                homepage: nil,
                docs: nil,
                repo: nil,
                lastUpdatedAt: metadata.lastUpdatedAt,
                pulseKind: metadata.pulseKind
            )
        }
    }
}
