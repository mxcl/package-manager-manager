import Foundation
import PMMCore

let menuBarRefreshInterval: TimeInterval = 55 * 60

struct MenuBarPackageRow: Equatable {
    let ecosystemTitle: String
    let ecosystemIcon: MenuBarEcosystemIcon
    let name: String
    let installedVersion: String
    let latestVersion: String
}

enum MenuBarEcosystemIcon: Equatable {
    case asset(name: String, fallbackSystemName: String)
    case paired(assetName: String, fallbackSystemName: String, systemName: String)
    case system(name: String)
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
        actionableOutdatedPackages.isEmpty ? "shippingbox" : "shippingbox.fill"
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
                    ecosystemTitle: $0.appProvenance?.title ?? $0.manager.title,
                    ecosystemIcon: menuBarEcosystemIcon(for: $0),
                    name: $0.displayName,
                    installedVersion: $0.installedVersion ?? "?",
                    latestVersion: $0.latestVersion ?? "?"
                )
            }
    }

    private var actionableOutdatedPackages: [ManagedPackage] {
        (inventory?.outdatedPackages ?? []).filter(PackageUpdater.supports)
    }
}

func menuBarEcosystemIcon(for package: ManagedPackage) -> MenuBarEcosystemIcon {
    if package.identifier.hasPrefix("brew:cask:"), package.appProvenance == .homebrew {
        return .paired(assetName: "EcosystemHomebrew", fallbackSystemName: "mug", systemName: "macwindow")
    }
    switch package.manager {
    case .apk, .apt, .dnf, .zypper:
        return .system(name: "shippingbox")
    case .homebrew:
        return .asset(name: "EcosystemHomebrew", fallbackSystemName: "mug")
    case .npm, .npx, .pnpm, .bun:
        return .asset(name: "EcosystemJavaScript", fallbackSystemName: "curlybraces")
    case .uv, .uvx, .pipx:
        return .asset(name: "EcosystemPython", fallbackSystemName: "arrow.forward.to.line")
    case .cargoInstall, .rustup:
        return .asset(name: "EcosystemRust", fallbackSystemName: "hammer")
    case .skills:
        return .system(name: "wand.and.stars")
    case .macApp:
        return switch package.appProvenance ?? .unknown {
        case .homebrew: .paired(assetName: "EcosystemHomebrew", fallbackSystemName: "mug", systemName: "macwindow")
        case .appStore: .asset(name: "EcosystemAppStore", fallbackSystemName: "storefront")
        case .setapp: .system(name: "square.grid.2x2")
        case .direct: .system(name: "macwindow")
        case .unknown: .system(name: "questionmark.app")
        }
    case .mise:
        return switch package.packageToken.lowercased() {
        case "node", "bun", "deno": .asset(name: "EcosystemJavaScript", fallbackSystemName: "curlybraces")
        case "python": .asset(name: "EcosystemPython", fallbackSystemName: "arrow.forward.to.line")
        case "rust": .asset(name: "EcosystemRust", fallbackSystemName: "hammer")
        default: .system(name: "curlybraces")
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

func menuBarCommandUpdateAllPackages(snapshot: PackageHostSnapshot, packageIDs: [String] = []) -> [ManagedPackage] {
    guard snapshot.runningAction == nil else { return [] }
    let selectedIDs = Set(packageIDs)
    return (snapshot.inventory?.outdatedPackages ?? []).filter {
        PackageUpdater.supports($0) && (selectedIDs.isEmpty || selectedIDs.contains($0.id))
    }
}

func menuBarCommandInstallPackages(ids: [String], snapshot: PackageHostSnapshot) -> [ManagedPackage] {
    guard snapshot.runningAction == nil else { return [] }
    return ids.compactMap { menuBarCommandPackage(id: $0, kind: .install, snapshot: snapshot) }
}

func menuBarShouldRefreshOnLaunch(snapshot: PackageHostSnapshot, now: Date = Date()) -> Bool {
    guard let inventory = snapshot.inventory else { return true }
    return snapshot.catalogPackages.isEmpty
        || snapshot.loadingManagers?.isEmpty == false
        || now.timeIntervalSince(inventory.generatedAt) >= menuBarRefreshInterval
}

/// What the host should do with an incoming helper install request.
enum MenuBarHelperInstallDisposition: Equatable {
    case start(CargoHelper)
    /// Hold it until the host goes idle, rather than dropping it.
    case hold(CargoHelper)
    case ignore
}

/// Decides whether a helper install can start now.
///
/// The app disables the card's button against a busy host, but that check and this cross-process
/// receive are not atomic: a refresh or an action can begin after the app observed an idle host and
/// before the notification arrives. Holding the request means the click still means something —
/// dropping it silently is what left the button doing nothing at all.
func menuBarHelperInstallDisposition(
    id: String,
    isBusy: Bool,
    installing: String? = nil
) -> MenuBarHelperInstallDisposition {
    guard let helper = CargoHelper(promptKey: id) else { return .ignore }
    // Two clicks can land before the first snapshot disables the button. Holding the second would
    // run the whole install again once the first finished, and both commands pass `--force`, so the
    // user really does sit through a second download or compile for nothing.
    guard id != installing else { return .ignore }
    return isBusy ? .hold(helper) : .start(helper)
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
