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
        catalogPackages(homebrewPrefix: nil)
    }

    public func catalogPackages(homebrewPrefix: String?) -> [ManagedPackage] {
        let packages = (
            managedPackages(for: .homebrew, identifierPrefix: "brew", metadata: formulas, homebrewPrefix: homebrewPrefix) +
            managedPackages(for: .homebrew, identifierPrefix: "brew:cask", metadata: casks, homebrewPrefix: homebrewPrefix) +
            managedPackages(for: .npm, identifierPrefix: "npm", metadata: npms)
        )
        return Dictionary(grouping: packages, by: \.id).compactMap { $0.value.first }
            .sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                let displayOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
                return $0.identifier < $1.identifier
            }
    }

    public func metadata(for manager: PackageManagerKind, name: String) -> PackageMetadata? {
        switch manager {
        case .cargoInstall, .rustup:
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
                summary: nonEmptyString(raw["summary"]),
                category: raw["category"] as? String,
                homepage: nonEmptyString(raw["homepage"]),
                docs: docsURL(raw),
                repo: nonEmptyString(raw["repository"]) ?? nonEmptyString(raw["repo"]),
                version: nonEmptyString(raw["version"]),
                lastUpdatedAt: raw["last_updated_at"] as? String,
                pulseKind: raw["pulse_kind"] as? String
            )
        }
    }

    private func managedPackages(
        for manager: PackageManagerKind,
        identifierPrefix: String,
        metadata: [String: PackageMetadata],
        homebrewPrefix: String? = nil
    ) -> [ManagedPackage] {
        metadata.map { name, metadata in
            ManagedPackage(
                manager: manager,
                identifier: "\(identifierPrefix):\(name)",
                displayName: name,
                installedVersion: nil,
                latestVersion: metadata.version,
                summary: metadata.summary,
                category: metadata.category,
                homepage: metadata.homepage,
                docs: metadata.docs,
                repo: metadata.repo,
                lastUpdatedAt: metadata.lastUpdatedAt,
                pulseKind: metadata.pulseKind,
                installLocation: homebrewInstallLocation(prefix: homebrewPrefix, identifierPrefix: identifierPrefix, name: name, version: metadata.version)
            )
        }
    }
}

private func homebrewInstallLocation(prefix: String?, identifierPrefix: String, name: String, version: String?) -> String? {
    guard let prefix, identifierPrefix.hasPrefix("brew") else { return nil }
    if identifierPrefix == "brew:cask" {
        return [prefix, "Caskroom", name, version].compactMap { $0 }.joined(separator: "/")
    }
    return "\(prefix)/opt/\(name)"
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
}

private func docsURL(_ raw: [String: Any]) -> String? {
    nonEmptyString(raw["docs"])
        ?? nonEmptyString(raw["upstreamDocs"])
        ?? (raw["docs"] as? [String])?.first(where: { !$0.isEmpty })
}
