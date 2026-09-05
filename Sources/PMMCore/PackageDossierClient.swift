import Foundation

public struct PackageDossierPage: Decodable, Equatable, Sendable {
    public let displayName: String?
    public let summary: String?
    public let category: String?
    public let version: String?
    public let license: String?
    public let homepage: String?
    public let repository: String?
    public let upstreamDocs: String?
    public let executables: [String]
    public let dependencies: [String]
    public let buildDependencies: [String]
    public let configFileLocations: [String: [String]]
    public let credentialsFileLocations: [String: [String]]
    public let alsoAvailableVia: [PackageDossierRelatedPackage]
    public let externalPackageManagerMatches: [PackageDossierExternalMatch]
    public let registryInsights: PackageDossierRegistryInsights?

    private enum RootKeys: String, CodingKey {
        case category
        case data
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case summary
        case category
        case version
        case license
        case homepage
        case repository
        case upstreamDocs
        case binaries
        case executablesDetailed
        case dependencies
        case buildDependencies
        case configFileLocations
        case credentialsFileLocations
        case alsoAvailableVia
        case externalPackageManagerMatches
        case registryInsights
        case extra
    }

    private enum ExtraKeys: String, CodingKey {
        case registryInsights
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        category = try container.decodeIfPresent(String.self, forKey: .category)
            ?? root.decodeIfPresent(String.self, forKey: .category)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        upstreamDocs = try container.decodeIfPresent(String.self, forKey: .upstreamDocs)
        let binaryNames = try container.decodeIfPresent([String].self, forKey: .binaries) ?? []
        let executableNames = try container.decodeIfPresent([PackageDossierExecutable].self, forKey: .executablesDetailed)?.map(\.name) ?? []
        executables = (binaryNames + executableNames).deduped()
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        buildDependencies = try container.decodeIfPresent([String].self, forKey: .buildDependencies) ?? []
        configFileLocations = try container.decodeIfPresent(PackageDossierStringMap.self, forKey: .configFileLocations)?.values ?? [:]
        credentialsFileLocations = try container.decodeIfPresent(PackageDossierStringMap.self, forKey: .credentialsFileLocations)?.values ?? [:]
        alsoAvailableVia = try container.decodeIfPresent([PackageDossierRelatedPackage].self, forKey: .alsoAvailableVia) ?? []
        externalPackageManagerMatches = try container.decodeIfPresent([PackageDossierExternalMatch].self, forKey: .externalPackageManagerMatches) ?? []
        let extra = try? container.nestedContainer(keyedBy: ExtraKeys.self, forKey: .extra)
        registryInsights = try container.decodeIfPresent(PackageDossierRegistryInsights.self, forKey: .registryInsights)
            ?? extra?.decodeIfPresent(PackageDossierRegistryInsights.self, forKey: .registryInsights)
    }
}

public struct PackageDossierRelatedPackage: Codable, Equatable, Sendable {
    public let provider: String?
    public let name: String?
    public let label: String?
}

public struct PackageDossierExternalMatch: Codable, Equatable, Sendable {
    public let displayName: String?
    public let command: String?
    public let platform: String?
}

public struct PackageDossierRegistryInsights: Codable, Equatable, Sendable {
    public let sourceDatabase: String?
    public let publisher: String?
    public let latestPublishedAt: String?
    public let modifiedAt: String?
    public let versionCount: Int?
    public let unpackedSize: Int?
    public let maintainers: [String]?
}

public struct PackageDossierClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://automicvault.com")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public func dossier(for package: ManagedPackage) async throws -> PackageDossierPage? {
        guard let url = Self.url(for: package, baseURL: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("PM2/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(PackageDossierPage.self, from: data)
    }

    public static func url(for package: ManagedPackage, baseURL: URL = URL(string: "https://automicvault.com")!) -> URL? {
        let catalogIdentifier = package.catalogIdentifier
        guard let provider = catalogIdentifier?.hasPrefix("brew:cask:") == true ? "brew" : provider(for: package) else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let name = catalogIdentifier?.split(separator: ":").last.map(String.init) ?? package.packageToken
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        components.percentEncodedPath = "/pkg/\(provider)/\(encodedName).json"
        return components.url
    }

    private static func provider(for package: ManagedPackage) -> String? {
        switch package.manager {
        case .homebrew:
            "brew"
        case .npm, .npx, .pnpm, .bun:
            "npm"
        case .cargoInstall:
            "cargo"
        case .apk, .apt, .dnf, .zypper, .macApp, .rustup, .mise, .skills, .pipx, .goInstall:
            nil
        case .uv, .uvx:
            "uv"
        }
    }
}

private struct PackageDossierExecutable: Codable {
    let name: String
}

private struct PackageDossierStringMap: Decodable {
    let values: [String: [String]]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PackageDossierDynamicKey.self)
        var values = [String: [String]]()
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                values[key.stringValue] = [value]
            } else if let value = try? container.decode([String].self, forKey: key) {
                values[key.stringValue] = value
            }
        }
        self.values = values
    }
}

private struct PackageDossierDynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

private extension Array where Element == String {
    func deduped() -> [String] {
        var seen = Set<String>()
        return filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
