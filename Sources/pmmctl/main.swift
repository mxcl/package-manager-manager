import Foundation
import PMMCore

let args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let outdatedOnly = args.contains("--outdated")

if args.contains("--help") {
    print("Usage: pmmctl [--json] [--outdated]")
    exit(0)
}

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
            ? "\(package.installedVersion ?? "?") -> \(package.latestVersion ?? "?")"
            : (package.installedVersion ?? "installed")
        let category = package.category.map { " [\($0)]" } ?? ""
        print("\(package.manager.title)\t\(package.name)\t\(status)\(category)")
    }
    for error in inventory.errors {
        fputs("warning: \(error)\n", stderr)
    }
}
