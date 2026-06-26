import Foundation

public enum PackageManagerKind: String, Codable, CaseIterable, Sendable {
    case homebrew
    case npm
    case npx

    public var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .npx: "npx"
        }
    }
}

public struct ManagedPackage: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(manager.rawValue):\(name):\(installLocation ?? "")" }

    public let manager: PackageManagerKind
    public let name: String
    public let installedVersion: String?
    public let latestVersion: String?
    public let summary: String?
    public let category: String?
    public let homepage: String?
    public let installLocation: String?
    public let binaryPath: String?

    public init(
        manager: PackageManagerKind,
        name: String,
        installedVersion: String?,
        latestVersion: String?,
        summary: String? = nil,
        category: String? = nil,
        homepage: String? = nil,
        installLocation: String? = nil,
        binaryPath: String? = nil
    ) {
        self.manager = manager
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.summary = summary
        self.category = category
        self.homepage = homepage
        self.installLocation = installLocation
        self.binaryPath = binaryPath
    }

    public var isOutdated: Bool {
        guard let installedVersion, let latestVersion else { return false }
        return !installedVersion.isEmpty && !latestVersion.isEmpty && installedVersion != latestVersion
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
    public let version: String?
}
