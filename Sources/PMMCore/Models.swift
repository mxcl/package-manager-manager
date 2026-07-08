import Foundation

public enum PackageManagerKind: String, Codable, CaseIterable, Sendable {
    case cargoInstall = "cargo-install"
    case rustup
    case homebrew
    case npm
    case npx
    case uv
    case uvx

    public var title: String {
        switch self {
        case .cargoInstall: "cargo install"
        case .rustup: "rustup"
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .npx: "npx"
        case .uv: "uv"
        case .uvx: "uvx"
        }
    }
}

public struct ManagedPackage: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(identifier):\(installLocation ?? "")" }

    public let manager: PackageManagerKind
    public let identifier: String
    public let displayName: String
    public let installedVersion: String?
    public let installedVersions: [String]
    public let latestVersion: String?
    public let summary: String?
    public let category: String?
    public let homepage: String?
    public let docs: String?
    public let repo: String?
    public let lastUpdatedAt: String?
    public let pulseKind: String?
    public let installLocation: String?
    public let binaryPath: String?
    public let executableNames: [String]

    public var name: String { identifier }

    public init(
        manager: PackageManagerKind,
        name: String,
        displayName: String? = nil,
        installedVersion: String?,
        installedVersions: [String] = [],
        latestVersion: String?,
        summary: String? = nil,
        category: String? = nil,
        homepage: String? = nil,
        docs: String? = nil,
        repo: String? = nil,
        lastUpdatedAt: String? = nil,
        pulseKind: String? = nil,
        installLocation: String? = nil,
        binaryPath: String? = nil,
        executableNames: [String] = []
    ) {
        self.init(
            manager: manager,
            identifier: name,
            displayName: displayName,
            installedVersion: installedVersion,
            installedVersions: installedVersions,
            latestVersion: latestVersion,
            summary: summary,
            category: category,
            homepage: homepage,
            docs: docs,
            repo: repo,
            lastUpdatedAt: lastUpdatedAt,
            pulseKind: pulseKind,
            installLocation: installLocation,
            binaryPath: binaryPath,
            executableNames: executableNames
        )
    }

    public init(
        manager: PackageManagerKind,
        identifier: String,
        displayName: String? = nil,
        installedVersion: String?,
        installedVersions: [String] = [],
        latestVersion: String?,
        summary: String? = nil,
        category: String? = nil,
        homepage: String? = nil,
        docs: String? = nil,
        repo: String? = nil,
        lastUpdatedAt: String? = nil,
        pulseKind: String? = nil,
        installLocation: String? = nil,
        binaryPath: String? = nil,
        executableNames: [String] = []
    ) {
        self.manager = manager
        self.identifier = identifier
        self.displayName = Self.normalizedDisplayName(displayName ?? identifier, manager: manager, identifier: identifier)
        self.installedVersion = installedVersion
        self.installedVersions = Self.normalizedVersions(installedVersions, including: installedVersion)
        self.latestVersion = latestVersion
        self.summary = summary
        self.category = category
        self.homepage = homepage
        self.docs = docs
        self.repo = repo
        self.lastUpdatedAt = lastUpdatedAt
        self.pulseKind = pulseKind
        self.installLocation = installLocation
        self.binaryPath = binaryPath
        self.executableNames = Self.normalizedExecutableNames(executableNames, binaryPath: binaryPath)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let manager = try container.decode(PackageManagerKind.self, forKey: .manager)
        let identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            ?? container.decode(String.self, forKey: .name)
        let displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? identifier
        let installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        let installedVersions = try container.decodeIfPresent([String].self, forKey: .installedVersions) ?? []
        let latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
        self.init(
            manager: manager,
            identifier: identifier,
            displayName: displayName,
            installedVersion: installedVersion,
            installedVersions: installedVersions,
            latestVersion: latestVersion,
            summary: try container.decodeIfPresent(String.self, forKey: .summary),
            category: try container.decodeIfPresent(String.self, forKey: .category),
            homepage: try container.decodeIfPresent(String.self, forKey: .homepage),
            docs: try container.decodeIfPresent(String.self, forKey: .docs),
            repo: try container.decodeIfPresent(String.self, forKey: .repo),
            lastUpdatedAt: try container.decodeIfPresent(String.self, forKey: .lastUpdatedAt),
            pulseKind: try container.decodeIfPresent(String.self, forKey: .pulseKind),
            installLocation: try container.decodeIfPresent(String.self, forKey: .installLocation),
            binaryPath: try container.decodeIfPresent(String.self, forKey: .binaryPath),
            executableNames: try container.decodeIfPresent([String].self, forKey: .executableNames) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manager, forKey: .manager)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(identifier, forKey: .name)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(installedVersion, forKey: .installedVersion)
        try container.encode(installedVersions, forKey: .installedVersions)
        try container.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(homepage, forKey: .homepage)
        try container.encodeIfPresent(docs, forKey: .docs)
        try container.encodeIfPresent(repo, forKey: .repo)
        try container.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encodeIfPresent(pulseKind, forKey: .pulseKind)
        try container.encodeIfPresent(installLocation, forKey: .installLocation)
        try container.encodeIfPresent(binaryPath, forKey: .binaryPath)
        if !executableNames.isEmpty {
            try container.encode(executableNames, forKey: .executableNames)
        }
    }

    public var isOutdated: Bool {
        guard let latestVersion, !latestVersion.isEmpty, !installedVersions.isEmpty else { return false }
        return !installedVersions.contains(latestVersion)
    }

    public var otherInstalledVersions: [String] {
        installedVersions.filter { $0 != installedVersion }
    }

    public func applying(metadata: PackageMetadata?) -> ManagedPackage {
        guard let metadata else { return self }
        return ManagedPackage(
            manager: manager,
            identifier: identifier,
            displayName: displayName,
            installedVersion: installedVersion,
            installedVersions: installedVersions,
            latestVersion: metadata.version ?? latestVersion,
            summary: metadata.summary ?? summary,
            category: metadata.category ?? category,
            homepage: metadata.homepage ?? homepage,
            docs: metadata.docs ?? docs,
            repo: metadata.repo ?? repo,
            lastUpdatedAt: metadata.lastUpdatedAt ?? lastUpdatedAt,
            pulseKind: metadata.pulseKind ?? pulseKind,
            installLocation: installLocation,
            binaryPath: binaryPath,
            executableNames: executableNames
        )
    }

    public static func consolidatingInstalledVersions(in packages: [ManagedPackage]) -> [ManagedPackage] {
        Dictionary(grouping: packages, by: \.identifier).values.compactMap { group in
            guard let newest = group.max(by: { ($0.installedVersion ?? "").localizedStandardCompare($1.installedVersion ?? "") == .orderedAscending }) else { return nil }
            return ManagedPackage(
                manager: newest.manager,
                identifier: newest.identifier,
                displayName: newest.displayName,
                installedVersion: newest.installedVersion,
                installedVersions: normalizedVersions(group.flatMap(\.installedVersions), including: newest.installedVersion),
                latestVersion: newest.latestVersion,
                summary: newest.summary,
                category: newest.category,
                homepage: newest.homepage,
                docs: newest.docs,
                repo: newest.repo,
                lastUpdatedAt: newest.lastUpdatedAt,
                pulseKind: newest.pulseKind,
                installLocation: newest.installLocation,
                binaryPath: newest.binaryPath,
                executableNames: newest.executableNames
            )
        }
        .sorted {
            if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
            let displayOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
            return $0.identifier < $1.identifier
        }
    }

    public var packageToken: String {
        identifier.split(separator: ":").last.map(String.init) ?? identifier
    }

    private static func normalizedVersions(_ versions: [String], including installedVersion: String?) -> [String] {
        Array(Set(versions + [installedVersion].compactMap { $0 }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    private static func normalizedExecutableNames(_ names: [String], binaryPath: String?) -> [String] {
        var seen = Set<String>()
        return (names + [binaryPath.map { URL(fileURLWithPath: $0).lastPathComponent }].compactMap { $0 })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func normalizedDisplayName(_ displayName: String, manager: PackageManagerKind, identifier: String) -> String {
        guard manager == .rustup, identifier.hasPrefix("rustup:toolchain:") else { return displayName }
        let toolchain = identifier.dropFirst("rustup:toolchain:".count)
        let suffix = "-aarch64-apple-darwin"
        guard toolchain.hasSuffix(suffix) else { return "rust \(toolchain)" }
        return "rust \(toolchain.dropLast(suffix.count)) ²"
    }

    private enum CodingKeys: String, CodingKey {
        case manager
        case identifier
        case name
        case displayName
        case installedVersion
        case installedVersions
        case latestVersion
        case summary
        case category
        case homepage
        case docs
        case repo
        case lastUpdatedAt
        case pulseKind
        case installLocation
        case binaryPath
        case executableNames
    }
}

public struct PackageInventory: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let packages: [ManagedPackage]
    public let errors: [String]

    public init(generatedAt: Date = Date(), packages: [ManagedPackage], errors: [String] = []) {
        self.generatedAt = generatedAt
        self.packages = packages
        self.errors = errors
    }

    public var outdatedPackages: [ManagedPackage] {
        packages.filter(\.isOutdated)
    }

    public var categoryCounts: [String: Int] {
        Dictionary(grouping: packages.compactMap(\.category), by: { $0 })
            .mapValues(\.count)
    }

    public var managerCounts: [PackageManagerKind: Int] {
        Dictionary(grouping: packages, by: \.manager).mapValues(\.count)
    }
}

public struct PackageMetadata: Equatable, Sendable {
    public let summary: String?
    public let category: String?
    public let homepage: String?
    public let docs: String?
    public let repo: String?
    public let version: String?
    public let lastUpdatedAt: String?
    public let pulseKind: String?

    public init(summary: String?, category: String?, homepage: String?, docs: String? = nil, repo: String? = nil, version: String?, lastUpdatedAt: String? = nil, pulseKind: String? = nil) {
        self.summary = summary
        self.category = category
        self.homepage = homepage
        self.docs = docs
        self.repo = repo
        self.version = version
        self.lastUpdatedAt = lastUpdatedAt
        self.pulseKind = pulseKind
    }
}
