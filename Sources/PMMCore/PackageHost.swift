import Foundation

public enum PackageHostActionKind: String, Codable, Sendable {
    case update
    case uninstall
}

public struct PackageHostRunningAction: Codable, Equatable, Sendable {
    public let kind: PackageHostActionKind
    public let packageID: String
    public let displayName: String

    public init(kind: PackageHostActionKind, packageID: String, displayName: String) {
        self.kind = kind
        self.packageID = packageID
        self.displayName = displayName
    }
}

public struct PackageHostSnapshot: Codable, Equatable, Sendable {
    public var inventory: PackageInventory?
    public var catalogPackages: [ManagedPackage]
    public var isRefreshing: Bool
    public var runningAction: PackageHostRunningAction?
    public var errorMessage: String?
    public var lastBrewUpdateAt: Date?

    public init(
        inventory: PackageInventory? = nil,
        catalogPackages: [ManagedPackage] = [],
        isRefreshing: Bool = false,
        runningAction: PackageHostRunningAction? = nil,
        errorMessage: String? = nil,
        lastBrewUpdateAt: Date? = nil
    ) {
        self.inventory = inventory
        self.catalogPackages = catalogPackages
        self.isRefreshing = isRefreshing
        self.runningAction = runningAction
        self.errorMessage = errorMessage
        self.lastBrewUpdateAt = lastBrewUpdateAt
    }
}

public struct PackageHostStore: Sendable {
    private let directory: URL

    public init(directory: URL = Self.defaultDirectory()) {
        self.directory = directory
    }

    public func load() throws -> PackageHostSnapshot? {
        let url = snapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PackageHostSnapshot.self, from: data)
    }

    public func save(_ snapshot: PackageHostSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    public var snapshotURL: URL {
        directory.appendingPathComponent("package-host-snapshot.json", isDirectory: false)
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Package Manager Manager", isDirectory: true)
    }
}

public enum PackageHostNotifications {
    public static let snapshotChanged = Notification.Name("dev.mxcl.pmm.packageHost.snapshotChanged")
    public static let refreshRequested = Notification.Name("dev.mxcl.pmm.packageHost.refreshRequested")
    public static let updateRequested = Notification.Name("dev.mxcl.pmm.packageHost.updateRequested")
    public static let uninstallRequested = Notification.Name("dev.mxcl.pmm.packageHost.uninstallRequested")

    public static let packageIDKey = "packageID"

    public static func postSnapshotChanged() {
        DistributedNotificationCenter.default().postNotificationName(snapshotChanged, object: nil, deliverImmediately: true)
    }

    public static func postRefreshRequested() {
        DistributedNotificationCenter.default().postNotificationName(refreshRequested, object: nil, deliverImmediately: true)
    }

    public static func postUpdateRequested(packageID: String) {
        postPackageCommand(updateRequested, packageID: packageID)
    }

    public static func postUninstallRequested(packageID: String) {
        postPackageCommand(uninstallRequested, packageID: packageID)
    }

    public static func packageID(from notification: Notification) -> String? {
        notification.userInfo?[packageIDKey] as? String
    }

    private static func postPackageCommand(_ name: Notification.Name, packageID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: [packageIDKey: packageID],
            deliverImmediately: true
        )
    }
}
