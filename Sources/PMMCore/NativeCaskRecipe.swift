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

    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.first != "-" && token.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || [45, 46, 43, 64].contains($0)
        } && !token.contains("..")
    }

    public static func decode(_ data: Data, token: String, osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                              osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                              arm64: Bool = NativeCaskRecipe.isAppleSilicon) throws -> NativeCaskRecipe {
        guard validToken(token), var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["token"] as? String == token, raw["tap"] as? String == "homebrew/cask" else {
            throw NativeCaskError("Only official Homebrew casks are supported by the native installer.")
        }
        let osNames = [26: "tahoe", 27: "golden_gate"]
        guard let osName = osNames[osMajor] else { throw NativeCaskError("Native cask installation is not supported on this macOS version yet.") }
        if let variations = raw["variations"] as? [String: [String: Any]],
           let variation = variations[(arm64 ? "arm64_" : "") + osName] {
            raw.merge(variation) { _, value in value }
        }
        guard raw["disabled"] as? Bool != true else { throw NativeCaskError("This cask has been disabled by Homebrew.") }
        guard let version = raw["version"] as? String, !version.isEmpty, version != "latest",
              let sha = raw["sha256"] as? String, sha.count == 64,
              sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let address = raw["url"] as? String, let url = URL(string: address),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw NativeCaskError("Native installation requires a versioned HTTPS download with a SHA-256 checksum.")
        }
        guard (raw["url_specs"] as? [String: Any] ?? [:]).isEmpty,
              raw["container"] == nil || raw["container"] is NSNull else {
            throw NativeCaskError("This cask needs a custom downloader or archive format. Use Homebrew.")
        }
        let dependencies = raw["depends_on"] as? [String: Any] ?? [:]
        guard Set(dependencies.keys).isSubset(of: ["macos", "arch"]) else {
            throw NativeCaskError("This cask requires dependencies. Use Homebrew.")
        }
        if let arch = dependencies["arch"] as? [String], !arch.contains(arm64 ? "arm64" : "x86_64") {
            throw NativeCaskError("This cask does not support this Mac’s architecture.")
        } else if dependencies["arch"] != nil && !(dependencies["arch"] is [String]) {
            throw NativeCaskError("This cask has unsupported architecture requirements.")
        }
        if let requirements = dependencies["macos"] as? [String: [String]] {
            let current = osVersion.first?.isNumber == true ? osVersion : "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)"
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
        } else if dependencies["macos"] != nil { throw NativeCaskError("This cask has unsupported macOS requirements.") }
        guard let artifacts = raw["artifacts"] as? [[String: Any]] else { throw NativeCaskError("Missing cask artifacts.") }
        var apps: [(String, String)] = []
        for artifact in artifacts {
            guard Set(artifact.keys).isSubset(of: ["app", "target", "binary", "command_wrapper", "zap", "uninstall"]) else {
                throw NativeCaskError("This cask requires an installer or script. Use Homebrew.")
            }
            if let uninstall = artifact["uninstall"] {
                guard let instructions = uninstall as? [[String: Any]],
                      instructions.allSatisfy({ Set($0.keys).isSubset(of: ["quit"]) }) else {
                    throw NativeCaskError("This cask requires additional uninstall actions. Use Homebrew.")
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
                                targetName: apps[0].1, conflicts: conflicts["cask"] as? [String] ?? [])
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
