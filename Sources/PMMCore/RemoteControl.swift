import Foundation

public let remoteControlProtocolVersion = 1

public struct RemoteControlFailure: Codable, Equatable, Sendable {
    public let packageID: String?
    public let message: String

    public init(packageID: String? = nil, message: String) {
        self.packageID = packageID
        self.message = message
    }
}

public struct RemoteControlResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let inventory: PackageInventory
    public let failures: [RemoteControlFailure]
    public let hostDescription: String?
    public let systemPackageManager: PackageManagerKind?
    public let canManageSystemPackages: Bool?
    public let nativeCaskManagementEnabled: Bool?

    public init(
        protocolVersion: Int = remoteControlProtocolVersion,
        inventory: PackageInventory,
        failures: [RemoteControlFailure] = [],
        hostDescription: String? = nil,
        systemPackageManager: PackageManagerKind? = nil,
        canManageSystemPackages: Bool? = nil,
        nativeCaskManagementEnabled: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.inventory = inventory
        self.failures = failures
        self.hostDescription = hostDescription
        self.systemPackageManager = systemPackageManager
        self.canManageSystemPackages = canManageSystemPackages
        self.nativeCaskManagementEnabled = nativeCaskManagementEnabled
    }
}

public enum RemoteControlCommand: Equatable, Sendable {
    case inventory
    case update(manager: PackageManagerKind, packageID: String)
    case uninstall(manager: PackageManagerKind, packageID: String)
    case updateAll

    public static func parse(_ arguments: [String]) throws -> RemoteControlCommand {
        guard let command = arguments.first else { throw RemoteControlCommandError.usage }
        let values = Array(arguments.dropFirst())
        guard value(for: "--protocol", in: values) == String(remoteControlProtocolVersion) else {
            throw RemoteControlCommandError.incompatibleProtocol
        }

        switch command {
        case "inventory":
            return .inventory
        case "update", "uninstall":
            guard let rawManager = value(for: "--manager", in: values),
                  let manager = PackageManagerKind(rawValue: rawManager),
                  let packageID = value(for: "--id", in: values), !packageID.isEmpty else {
                throw RemoteControlCommandError.usage
            }
            return command == "update"
                ? .update(manager: manager, packageID: packageID)
                : .uninstall(manager: manager, packageID: packageID)
        case "update-all":
            return .updateAll
        default:
            throw RemoteControlCommandError.usage
        }
    }

    private static func value(for option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

public enum RemoteControlCommandError: LocalizedError, Equatable {
    case usage
    case incompatibleProtocol

    public var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: pmmctl remote inventory|update|uninstall|update-all --protocol \(remoteControlProtocolVersion) [--manager <manager> --id <package-id>]"
        case .incompatibleProtocol:
            "This version of Package Manager Manager does not support the requested remote-control protocol. Update Package Manager Manager on the remote Mac."
        }
    }
}
