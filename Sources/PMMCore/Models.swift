import Foundation

public enum PackageManagerKind: String, Codable, CaseIterable, Sendable {
    case apk
    case apt
    case bun
    case cargoInstall = "cargo-install"
    case dnf
    case goInstall = "go-install"
    case macApp = "mac-app"
    case rustup
    case homebrew
    case mise
    case npm
    case npx
    case pipx
    case pnpm
    case skills
    case uv
    case uvx
    case zypper

    public static let localCases = allCases.filter { !$0.isLinuxSystem }

    public var isLinuxSystem: Bool {
        switch self {
        case .apk, .apt, .dnf, .zypper: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .apk: "apk"
        case .apt: "APT"
        case .bun: "Bun"
        case .cargoInstall: "cargo install"
        case .dnf: "DNF"
        case .goInstall: "go install"
        case .macApp: "App"
        case .rustup: "rustup"
        case .homebrew: "Homebrew"
        case .mise: "mise"
        case .npm: "npm"
        case .npx: "npx"
        case .pipx: "pipx"
        case .pnpm: "pnpm"
        case .skills: "Skills"
        case .uv: "uv"
        case .uvx: "uvx"
        case .zypper: "Zypper"
        }
    }
}

public enum MacAppProvenance: String, Codable, CaseIterable, Sendable {
    case homebrew
    case appStore = "app-store"
    case setapp
    case direct
    case unknown

    public var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .appStore: "App Store"
        case .setapp: "Setapp"
        case .direct: "DIY"
        case .unknown: "Unknown"
        }
    }
}

public enum MacAppVersionSource: String, Codable, Sendable {
    case appStore = "app-store"
    case setapp
    case sparkle
    case homebrewCask = "homebrew-cask"

    public var title: String {
        switch self {
        case .appStore: "App Store"
        case .setapp: "Setapp"
        case .sparkle: "Sparkle"
        case .homebrewCask: "Homebrew Cask"
        }
    }
}

public struct MacAppCatalogEntry: Equatable, Sendable {
    public let bundleIdentifier: String
    public let cask: String?
    public let feedURL: String?
    public let appStoreID: Int?
    public let channel: String?
    public let versionSource: MacAppVersionSource?
    public let advisoryURL: String?
    public let summary: String?
    public let category: String?
    public let homepage: String?
    public let version: String?

    public init(
        bundleIdentifier: String,
        cask: String? = nil,
        feedURL: String? = nil,
        appStoreID: Int? = nil,
        channel: String? = nil,
        versionSource: MacAppVersionSource? = nil,
        advisoryURL: String? = nil,
        summary: String? = nil,
        category: String? = nil,
        homepage: String? = nil,
        version: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.cask = cask
        self.feedURL = feedURL
        self.appStoreID = appStoreID
        self.channel = channel
        self.versionSource = versionSource
        self.advisoryURL = advisoryURL
        self.summary = summary
        self.category = category
        self.homepage = homepage
        self.version = version
    }

    func applyingFallback(_ metadata: PackageMetadata) -> MacAppCatalogEntry {
        MacAppCatalogEntry(
            bundleIdentifier: bundleIdentifier,
            cask: cask,
            feedURL: feedURL,
            appStoreID: appStoreID,
            channel: channel,
            versionSource: versionSource,
            advisoryURL: advisoryURL,
            summary: summary ?? metadata.summary,
            category: category ?? metadata.category,
            homepage: homepage ?? metadata.homepage,
            version: version ?? metadata.version
        )
    }
}

public struct ManagedPackage: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(identifier):\(installLocation ?? "")" }

    public let manager: PackageManagerKind
    public let identifier: String
    public let catalogIdentifier: String?
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
    public let bundleIdentifier: String?
    public let bundleVersion: String?
    public let appProvenance: MacAppProvenance?
    public let versionSource: MacAppVersionSource?
    public let advisoryURL: String?
    public let versionCheckedAt: Date?

    public var name: String { identifier }

    public init(
        manager: PackageManagerKind,
        name: String,
        catalogIdentifier: String? = nil,
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
        executableNames: [String] = [],
        bundleIdentifier: String? = nil,
        bundleVersion: String? = nil,
        appProvenance: MacAppProvenance? = nil,
        versionSource: MacAppVersionSource? = nil,
        advisoryURL: String? = nil,
        versionCheckedAt: Date? = nil
    ) {
        self.init(
            manager: manager,
            identifier: name,
            catalogIdentifier: catalogIdentifier,
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
            executableNames: executableNames,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            appProvenance: appProvenance,
            versionSource: versionSource,
            advisoryURL: advisoryURL,
            versionCheckedAt: versionCheckedAt
        )
    }

    public init(
        manager: PackageManagerKind,
        identifier: String,
        catalogIdentifier: String? = nil,
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
        executableNames: [String] = [],
        bundleIdentifier: String? = nil,
        bundleVersion: String? = nil,
        appProvenance: MacAppProvenance? = nil,
        versionSource: MacAppVersionSource? = nil,
        advisoryURL: String? = nil,
        versionCheckedAt: Date? = nil
    ) {
        self.manager = manager
        self.identifier = identifier
        self.catalogIdentifier = catalogIdentifier
        self.displayName = Self.normalizedDisplayName(displayName ?? identifier, manager: manager, identifier: identifier)
        self.installedVersion = installedVersion
        self.installedVersions = Self.normalizedVersions(installedVersions, including: installedVersion)
        self.latestVersion = latestVersion
        self.summary = Self.normalizedSummary(summary, manager: manager, identifier: identifier)
        self.category = category
        self.homepage = homepage
        self.docs = docs
        self.repo = repo
        self.lastUpdatedAt = lastUpdatedAt
        self.pulseKind = pulseKind
        self.installLocation = installLocation
        self.binaryPath = binaryPath
        self.executableNames = Self.normalizedExecutableNames(executableNames, binaryPath: binaryPath)
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.appProvenance = appProvenance
        self.versionSource = versionSource
        self.advisoryURL = advisoryURL
        self.versionCheckedAt = versionCheckedAt
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
            catalogIdentifier: try container.decodeIfPresent(String.self, forKey: .catalogIdentifier),
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
            executableNames: try container.decodeIfPresent([String].self, forKey: .executableNames) ?? [],
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            bundleVersion: try container.decodeIfPresent(String.self, forKey: .bundleVersion),
            appProvenance: try container.decodeIfPresent(MacAppProvenance.self, forKey: .appProvenance),
            versionSource: try container.decodeIfPresent(MacAppVersionSource.self, forKey: .versionSource),
            advisoryURL: try container.decodeIfPresent(String.self, forKey: .advisoryURL),
            versionCheckedAt: try container.decodeIfPresent(Date.self, forKey: .versionCheckedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manager, forKey: .manager)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(identifier, forKey: .name)
        try container.encodeIfPresent(catalogIdentifier, forKey: .catalogIdentifier)
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
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(bundleVersion, forKey: .bundleVersion)
        try container.encodeIfPresent(appProvenance, forKey: .appProvenance)
        try container.encodeIfPresent(versionSource, forKey: .versionSource)
        try container.encodeIfPresent(advisoryURL, forKey: .advisoryURL)
        try container.encodeIfPresent(versionCheckedAt, forKey: .versionCheckedAt)
    }

    public var isOutdated: Bool {
        guard let latestVersion, !latestVersion.isEmpty, !installedVersions.isEmpty else { return false }
        return !installedVersions.contains(latestVersion)
    }

    public var otherInstalledVersions: [String] {
        installedVersions.filter { $0 != installedVersion }
    }

    /// Folds catalogued description into a package the scanners produced.
    ///
    /// The catalog owns what a package *is* — summary, category, homepage, docs — because it is the
    /// only source for those. It does not own `latestVersion`, which is state somebody observed:
    /// brew's `outdated`, cargo-update's list, a registry query. So the catalog fills that in when
    /// nothing looked, and never overwrites an answer when something did. The other way round, a
    /// crate that cargo-update had just reported as outdated would drop back out of Outdated
    /// seconds later because a stale catalog said the installed version was current.
    public func applying(metadata: PackageMetadata?) -> ManagedPackage {
        guard let metadata else { return self }
        return ManagedPackage(
            manager: manager,
            identifier: identifier,
            catalogIdentifier: catalogIdentifier,
            displayName: metadata.displayName ?? displayName,
            installedVersion: installedVersion,
            installedVersions: installedVersions,
            latestVersion: latestVersion ?? metadata.version,
            summary: metadata.summary ?? summary,
            category: metadata.category ?? category,
            homepage: metadata.homepage ?? homepage,
            docs: metadata.docs ?? docs,
            repo: metadata.repo ?? repo,
            lastUpdatedAt: metadata.lastUpdatedAt ?? lastUpdatedAt,
            pulseKind: metadata.pulseKind ?? pulseKind,
            installLocation: installLocation,
            binaryPath: binaryPath,
            executableNames: executableNames,
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            appProvenance: appProvenance,
            versionSource: versionSource,
            advisoryURL: advisoryURL,
            versionCheckedAt: versionCheckedAt
        )
    }

    public static func consolidatingInstalledVersions(in packages: [ManagedPackage]) -> [ManagedPackage] {
        Dictionary(grouping: packages, by: \.identifier).values.compactMap { group in
            guard let newest = group.max(by: { ($0.installedVersion ?? "").localizedStandardCompare($1.installedVersion ?? "") == .orderedAscending }) else { return nil }
            return ManagedPackage(
                manager: newest.manager,
                identifier: newest.identifier,
                catalogIdentifier: newest.catalogIdentifier,
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
                executableNames: newest.executableNames,
                bundleIdentifier: newest.bundleIdentifier,
                bundleVersion: newest.bundleVersion,
                appProvenance: newest.appProvenance,
                versionSource: newest.versionSource,
                advisoryURL: newest.advisoryURL,
                versionCheckedAt: newest.versionCheckedAt
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

    private static func normalizedSummary(_ summary: String?, manager: PackageManagerKind, identifier: String) -> String? {
        guard manager == .rustup, identifier.hasPrefix("rustup:toolchain:") else { return summary }
        return "rustup managed Rust toolchain"
    }

    private enum CodingKeys: String, CodingKey {
        case manager
        case identifier
        case catalogIdentifier
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
        case bundleIdentifier
        case bundleVersion
        case appProvenance
        case versionSource
        case advisoryURL
        case versionCheckedAt
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
    public let displayName: String?
    public let summary: String?
    public let category: String?
    public let homepage: String?
    public let docs: String?
    public let repo: String?
    public let version: String?
    public let lastUpdatedAt: String?
    public let pulseKind: String?

    public init(displayName: String? = nil, summary: String?, category: String?, homepage: String?, docs: String? = nil, repo: String? = nil, version: String?, lastUpdatedAt: String? = nil, pulseKind: String? = nil) {
        self.displayName = displayName
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
