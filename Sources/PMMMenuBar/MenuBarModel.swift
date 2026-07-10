import Foundation
import PMMCore

let menuBarRefreshInterval: TimeInterval = 55 * 60

struct MenuBarPackageRow: Equatable {
    let managerTitle: String
    let name: String
    let installedVersion: String
    let latestVersion: String
}

enum MenuBarMenuRow: Equatable {
    case loading
    case empty
    case error(String)
    case package(MenuBarPackageRow)
}

struct MenuBarMenuState: Equatable {
    var inventory: PackageInventory?
    var isRefreshing = false
    var errorMessage: String?

    var statusSymbolName: String {
        outdatedRows.isEmpty ? "shippingbox.fill" : "shippingbox"
    }

    var rows: [MenuBarMenuRow] {
        var rows: [MenuBarMenuRow] = []
        if inventory == nil || isRefreshing {
            rows.append(.loading)
        }
        if let errorMessage {
            rows.append(.error(errorMessage))
        }
        if inventory != nil {
            let packages = outdatedRows
            rows += packages.map(MenuBarMenuRow.package)
            if packages.isEmpty, !isRefreshing {
                rows.append(.empty)
            }
        }
        return rows
    }

    private var outdatedRows: [MenuBarPackageRow] {
        (inventory?.outdatedPackages ?? [])
            .sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                let displayOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
                return $0.identifier < $1.identifier
            }
            .map {
                MenuBarPackageRow(
                    managerTitle: $0.manager.title,
                    name: $0.displayName,
                    installedVersion: $0.installedVersion ?? "?",
                    latestVersion: $0.latestVersion ?? "?"
                )
            }
    }
}

func menuBarCommandPackage(id: String, kind: PackageHostActionKind, snapshot: PackageHostSnapshot) -> ManagedPackage? {
    guard snapshot.runningAction == nil else { return nil }
    let installedPackage = snapshot.inventory?.packages.first { $0.id == id }
    let catalogPackage = snapshot.catalogPackages.first { $0.id == id }
    switch kind {
    case .install:
        guard let package = catalogPackage else { return nil }
        let isInstalled = snapshot.inventory?.packages.contains { $0.identifier == package.identifier } == true
        return !isInstalled && PackageInstaller.supports(package) ? package : nil
    case .update:
        guard let package = installedPackage else { return nil }
        return PackageUpdater.supports(package) ? package : nil
    case .uninstall:
        guard let package = installedPackage else { return nil }
        return PackageUninstaller.supports(package) ? package : nil
    }
}

func menuBarCommandUpdateAllPackages(snapshot: PackageHostSnapshot) -> [ManagedPackage] {
    guard snapshot.runningAction == nil else { return [] }
    return (snapshot.inventory?.outdatedPackages ?? []).filter(PackageUpdater.supports)
}

func menuBarCommandInstallPackages(ids: [String], snapshot: PackageHostSnapshot) -> [ManagedPackage] {
    guard snapshot.runningAction == nil else { return [] }
    return ids.compactMap { menuBarCommandPackage(id: $0, kind: .install, snapshot: snapshot) }
}

func menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot, now: Date = Date()) -> Bool {
    guard let inventory = snapshot.inventory else { return true }
    return snapshot.loadingManagers?.isEmpty == false
        || now.timeIntervalSince(inventory.generatedAt) >= menuBarRefreshInterval
}

func menuBarSnapshot(
    _ snapshot: PackageHostSnapshot,
    merging result: PackageManagerScanResult,
    generatedAt: Date,
    errors: [String]
) -> PackageHostSnapshot {
    var snapshot = snapshot
    let existing = snapshot.inventory?.packages ?? []
    let packages = (existing.filter { $0.manager != result.manager } + result.packages).sorted {
        if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
        let displayOrder = $0.displayName.localizedStandardCompare($1.displayName)
        if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
        return $0.identifier < $1.identifier
    }
    snapshot.inventory = PackageInventory(generatedAt: generatedAt, packages: packages, errors: errors)
    return snapshot
}

func menuBarSnapshot(
    _ snapshot: PackageHostSnapshot,
    applyingSuccessfulAction kind: PackageHostActionKind,
    package: ManagedPackage
) -> PackageHostSnapshot {
    guard let inventory = snapshot.inventory else { return snapshot }
    var snapshot = snapshot
    var packages = inventory.packages

    switch kind {
    case .install:
        if !packages.contains(where: { $0.identifier == package.identifier }) {
            packages.append(package.withInstalledVersion(package.latestVersion))
        }
    case .update:
        guard let latestVersion = package.latestVersion,
              let index = packages.firstIndex(where: { $0.id == package.id }) else { return snapshot }
        packages[index] = package.withInstalledVersion(latestVersion)
    case .uninstall:
        if package.manager == .uv, package.summary == "uv-managed Python", let nextVersion = package.otherInstalledVersions.first,
           let index = packages.firstIndex(where: { $0.id == package.id }) {
            packages[index] = package.withInstalledVersion(nextVersion, installedVersions: package.otherInstalledVersions)
        } else {
            packages.removeAll { $0.id == package.id }
        }
    }

    snapshot.inventory = PackageInventory(packages: packages, errors: inventory.errors)
    return snapshot
}

private extension ManagedPackage {
    func withInstalledVersion(_ version: String?, installedVersions: [String]? = nil) -> ManagedPackage {
        ManagedPackage(
            manager: manager,
            identifier: identifier,
            displayName: displayName,
            installedVersion: version,
            installedVersions: installedVersions ?? self.installedVersions,
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
}
