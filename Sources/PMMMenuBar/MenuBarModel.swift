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
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map {
                MenuBarPackageRow(
                    managerTitle: $0.manager.title,
                    name: $0.name,
                    installedVersion: $0.installedVersion ?? "?",
                    latestVersion: $0.latestVersion ?? "?"
                )
            }
    }
}
