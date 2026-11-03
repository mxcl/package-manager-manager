import Foundation
import PMMCore

/// Serializes disk reads away from the main actor and reuses catalog/index work between
/// progress-only snapshots. A cancelled refresh never publishes over its successor.
actor HostSnapshotLoader {
    private let store: PackageHostStore
    private var catalog: [ManagedPackage]?
    private var indexedPackages: [ManagedPackage]?
    private var indexedCatalog: [ManagedPackage]?
    private var indexedClickedAt: Date?
    private var index: PackageIndex?

    init(store: PackageHostStore, catalog: [ManagedPackage]?) {
        self.store = store
        self.catalog = catalog
    }

    func load(clickedAt: Date?) -> (PackageHostSnapshot, PackageIndex)? {
        guard !Task.isCancelled else { return nil }
        if catalog == nil { catalog = PackageHostStore.bundledCatalog() }
        let fallback = catalog ?? []
        guard var snapshot = (try? store.load()) ?? (fallback.isEmpty ? nil : PackageHostSnapshot()) else { return nil }
        if snapshot.catalogPackages.isEmpty { snapshot.catalogPackages = fallback }
        let packages = snapshot.inventory?.packages ?? []
        guard !Task.isCancelled else { return nil }
        if index == nil || indexedPackages != packages || indexedCatalog != snapshot.catalogPackages || indexedClickedAt != clickedAt {
            index = PackageIndex(packages: packages, catalogPackages: snapshot.catalogPackages, newUpdatedLastClickedAt: clickedAt)
            indexedPackages = packages
            indexedCatalog = snapshot.catalogPackages
            indexedClickedAt = clickedAt
        }
        return (snapshot, index!)
    }
}
