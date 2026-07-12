import Foundation
import PMMCore

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--help") {
    print("""
    Usage: pmmctl [--json] [--outdated]
           pmmctl remote inventory --protocol \(remoteControlProtocolVersion)
           pmmctl remote update --protocol \(remoteControlProtocolVersion) --manager <manager> --id <package-id>
           pmmctl remote uninstall --protocol \(remoteControlProtocolVersion) --manager <manager> --id <package-id>
           pmmctl remote update-all --protocol \(remoteControlProtocolVersion)
    """)
    exit(0)
}

if args.first == "remote" {
    let command: RemoteControlCommand
    do {
        command = try RemoteControlCommand.parse(Array(args.dropFirst()))
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(64)
    }

    let database = await PackageDatabase.load()
    let scanner = PackageScanner()
    var inventory = await scanner.inventory(database: database)
    var failures = [RemoteControlFailure]()

    func perform(_ package: ManagedPackage, update: Bool) async -> RemoteControlFailure? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let report: @Sendable (PackageCommandProgress) -> Void = { progress in
                    let text = switch progress {
                    case .started(let command): "$ \(command)\n"
                    case .output(let output): output
                    }
                    FileHandle.standardError.write(Data(text.utf8))
                }
                do {
                    if update {
                        try PackageUpdater().update(package, onProgress: report)
                    } else {
                        try PackageUninstaller().uninstall(package, onProgress: report)
                    }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: RemoteControlFailure(packageID: package.id, message: error.localizedDescription))
                }
            }
        }
    }

    switch command {
    case .inventory:
        break
    case .update(let manager, let packageID):
        if let package = inventory.packages.first(where: { $0.manager == manager && $0.id == packageID }),
           PackageUpdater.supports(package) {
            if let failure = await perform(package, update: true) { failures.append(failure) }
        } else {
            failures.append(RemoteControlFailure(packageID: packageID, message: "The package is missing, current, or cannot be updated."))
        }
        inventory = await scanner.inventory(database: database)
        PackageHostNotifications.postRefreshRequested()
    case .uninstall(let manager, let packageID):
        if let package = inventory.packages.first(where: { $0.manager == manager && $0.id == packageID }),
           PackageUninstaller.supports(package) {
            if let failure = await perform(package, update: false) { failures.append(failure) }
        } else {
            failures.append(RemoteControlFailure(packageID: packageID, message: "The package is missing or cannot be uninstalled."))
        }
        inventory = await scanner.inventory(database: database)
        PackageHostNotifications.postRefreshRequested()
    case .updateAll:
        for package in inventory.outdatedPackages where PackageUpdater.supports(package) {
            if let failure = await perform(package, update: true) { failures.append(failure) }
        }
        inventory = await scanner.inventory(database: database)
        PackageHostNotifications.postRefreshRequested()
    }

    let response = RemoteControlResponse(inventory: inventory, failures: failures)
    FileHandle.standardOutput.write(try JSONEncoder().encode(response))
    exit(failures.isEmpty ? 0 : 1)
}

let json = args.contains("--json")
let outdatedOnly = args.contains("--outdated")

let database = await PackageDatabase.load()
let inventory = await PackageScanner().inventory(database: database)
let packages = outdatedOnly ? inventory.outdatedPackages : inventory.packages

if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(PackageInventory(packages: packages, errors: inventory.errors)))
} else {
    for package in packages {
        let status = package.isOutdated
            ? "\(package.installedVersion ?? "?") → \(package.latestVersion ?? "?")"
            : (package.installedVersion ?? "installed")
        let category = package.category.map { " [\($0)]" } ?? ""
        print("\(package.manager.title)\t\(package.displayName)\t\(status)\(category)")
    }
    for error in inventory.errors {
        fputs("warning: \(error)\n", stderr)
    }
}
