import Foundation
import PMMCore

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
    guard snapshot.runningAction == nil,
          let package = snapshot.inventory?.packages.first(where: { $0.id == id }) else { return nil }
    switch kind {
    case .update:
        return PackageUpdater.supports(package) ? package : nil
    case .uninstall:
        return package.installedVersion == nil ? nil : package
    }
}

func menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot) -> Bool {
    snapshot.inventory == nil
}
