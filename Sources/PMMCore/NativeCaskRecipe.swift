import Foundation
import Darwin

public struct NativeCaskError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The deliberately small, declarative subset we can install without running Ruby.
public struct NativeCaskRecipe: Equatable, Sendable {
    public let token: String
    public let version: String
    public let url: URL
    public let sha256: String
    public let app: String
    public let targetName: String
    public let conflicts: [String]
    public let quitBundleIdentifiers: [String]

    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.first != "-" && token.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || [45, 46, 43, 64].contains($0)
        } && !token.contains("..")
    }

    public static func decode(_ data: Data, token: String, osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                              osVersion: String = NativeCaskRecipe.currentOSVersion,
                              arm64: Bool = NativeCaskRecipe.isAppleSilicon) throws -> NativeCaskRecipe {
        guard validToken(token), var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["token"] as? String == token, raw["tap"] as? String == "homebrew/cask" else {
            throw NativeCaskError("Only official Homebrew casks are supported by the native installer.")
        }
        for key in ["variations", "url_specs", "depends_on", "conflicts_with"] {
            if let value = raw[key], !(value is NSNull), !(value is [String: Any]) {
                throw NativeCaskError("Malformed cask \(key) metadata.")
            }
        }
        if let variations = raw["variations"], !(variations is NSNull), !(variations is [String: [String: Any]]) {
            throw NativeCaskError("Malformed cask variations.")
        }
        let osNames = [26: "tahoe", 27: "golden_gate"]
        guard let osName = osNames[osMajor] else { throw NativeCaskError("Native cask installation is not supported on this macOS version yet.") }
        if let variations = raw["variations"] as? [String: [String: Any]],
           let variation = variations[(arm64 ? "arm64_" : "") + osName] {
            raw.merge(variation) { _, value in value }
        }
        // Variations may override requirements; validate their shape after selecting this Mac.
        for key in ["url_specs", "depends_on", "conflicts_with"] {
            if let value = raw[key], !(value is NSNull), !(value is [String: Any]) {
                throw NativeCaskError("Malformed cask \(key) metadata.")
            }
        }
        guard raw["disabled"] as? Bool != true else { throw NativeCaskError("This cask has been disabled by Homebrew.") }
        guard let version = raw["version"] as? String, !version.isEmpty, version != "latest" else {
            throw NativeCaskError("This cask does not specify a fixed version. Native management is unavailable.")
        }
        guard let sha = raw["sha256"] as? String, sha.count == 64,
              sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NativeCaskError("This cask does not provide a SHA-256 checksum. PMM cannot verify its download.")
        }
        guard let address = raw["url"] as? String, let url = URL(string: address),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw NativeCaskError("This cask does not provide a supported HTTPS download URL.")
        }
        let urlSpecs = raw["url_specs"] as? [String: Any] ?? [:]
        let container = raw["container"] as? [String: String]
        let supportedContainer = raw["container"] == nil || raw["container"] is NSNull
            || (container?.count == 1 && ["zip", "dmg"].contains(container?["type"] ?? ""))
        guard Set(urlSpecs.keys).isSubset(of: ["verified"]), supportedContainer else {
            throw NativeCaskError("This cask needs a custom downloader or archive format. Use Homebrew.")
        }
        let dependencies = raw["depends_on"] as? [String: Any] ?? [:]
        guard Set(dependencies.keys).isSubset(of: ["macos", "maximum_macos", "arch"]) else {
            throw NativeCaskError("This cask requires dependencies. Use Homebrew.")
        }
        if let value = dependencies["arch"] {
            // Homebrew's API encodes architectures as {type: "arm"|"intel", bits: 64}.
            guard let architectures = value as? [[String: Any]],
                  architectures.contains(where: { $0["type"] as? String == (arm64 ? "arm" : "intel") && $0["bits"] as? Int == 64 }) else {
                throw NativeCaskError("This cask does not support this Mac’s architecture.")
            }
        }
        for key in ["macos", "maximum_macos"] {
            if let requirements = dependencies[key] as? [String: [String]] {
                let current = osVersion
                for (op, versions) in requirements {
                    let matches = versions.contains { required in
                        guard let order = numericVersionComparison(current, required) else { return false }
                        switch op {
                        case ">=": return order != .orderedAscending
                        case ">": return order == .orderedDescending
                        case "<=": return order != .orderedDescending
                        case "<": return order == .orderedAscending
                        case "==", "=": return order == .orderedSame
                        default: return false
                        }
                    }
                    guard matches else { throw NativeCaskError("This cask does not support this version of macOS.") }
                }
            } else if dependencies[key] != nil { throw NativeCaskError("This cask has unsupported macOS requirements.") }
        }
        guard let artifacts = raw["artifacts"] as? [[String: Any]] else { throw NativeCaskError("Missing cask artifacts.") }
        var apps: [(String, String)] = []
        var quitIDs: [String] = []
        for artifact in artifacts {
            guard Set(artifact.keys).isSubset(of: ["app", "target", "binary", "command_wrapper", "zap", "uninstall"]) else {
                throw NativeCaskError("This cask requires an installer or script. Use Homebrew.")
            }
            if let uninstall = artifact["uninstall"] {
                guard let instructions = uninstall as? [[String: Any]],
                      instructions.allSatisfy({ Set($0.keys).isSubset(of: ["quit"]) }) else {
                    throw NativeCaskError("This cask requires additional uninstall actions. Use Homebrew.")
                }
                for instruction in instructions {
                    if let id = instruction["quit"] as? String { quitIDs.append(id) }
                    else if let ids = instruction["quit"] as? [String] { quitIDs += ids }
                    else { throw NativeCaskError("Unsupported quit instruction.") }
                }
            }
            if let value = artifact["app"] {
                guard let values = value as? [Any], let source = values.first as? String,
                      safeRelativePath(source), source.hasSuffix(".app"), values.count <= 2 else {
                    throw NativeCaskError("Unsupported app artifact path.")
                }
                let options = values.count == 2 ? values[1] as? [String: String] : nil
                if values.count == 2 && (options == nil || Set(options!.keys) != ["target"]) {
                    throw NativeCaskError("Unsupported app artifact options.")
                }
                let target = artifact["target"] as? String ?? options?["target"] ?? URL(fileURLWithPath: source).lastPathComponent
                let name = target.hasPrefix("/Applications/") ? String(target.dropFirst("/Applications/".count)) : target
                guard safeRelativePath(name), !name.contains("/"), name.hasSuffix(".app") else {
                    throw NativeCaskError("This cask uses a custom installation location.")
                }
                apps.append((source, name))
            }
        }
        guard apps.count == 1 else { throw NativeCaskError("Native installation supports casks containing exactly one app.") }
        let conflicts = raw["conflicts_with"] as? [String: Any] ?? [:]
        guard Set(conflicts.keys).isSubset(of: ["cask"]),
              conflicts.isEmpty || conflicts["cask"] is [String] else { throw NativeCaskError("Unsupported cask conflicts.") }
        return NativeCaskRecipe(token: token, version: version, url: url, sha256: sha, app: apps[0].0,
                                targetName: apps[0].1, conflicts: conflicts["cask"] as? [String] ?? [], quitBundleIdentifiers: quitIDs)
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    public static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
