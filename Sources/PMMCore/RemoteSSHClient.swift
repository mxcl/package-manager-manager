import Foundation

public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String?
    public var destination: String

    public init(id: UUID = UUID(), name: String? = nil, destination: String) throws {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidDestination(destination) else { throw RemoteHostError.invalidDestination }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = normalizedName?.isEmpty == false ? normalizedName : nil
        self.destination = destination
    }

    public var displayName: String { name ?? destination }

    public static func isValidDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, destination.count <= 255, !destination.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._@:%+-[]"))
        return destination.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public struct RemoteSSHClient: Sendable {
    public static let controlExecutable = "/Applications/Package Manager Manager.app/Contents/Helpers/pmmctl"

    private let runner: CommandRunning
    private let sshExecutable: String

    public init(runner: CommandRunning = SystemCommandRunner(), sshExecutable: String = "/usr/bin/ssh") {
        self.runner = runner
        self.sshExecutable = sshExecutable
    }

    public func inventory(on host: RemoteHost) async throws -> RemoteControlResponse {
        try await run(host, arguments: ["inventory", "--protocol", String(remoteControlProtocolVersion)])
    }

    public func update(
        _ package: ManagedPackage,
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(host, arguments: [
            "update", "--protocol", String(remoteControlProtocolVersion),
            "--manager", package.manager.rawValue, "--id", package.id,
        ], onProgress: onProgress)
    }

    public func uninstall(
        _ package: ManagedPackage,
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(host, arguments: [
            "uninstall", "--protocol", String(remoteControlProtocolVersion),
            "--manager", package.manager.rawValue, "--id", package.id,
        ], onProgress: onProgress)
    }

    public func updateAll(
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(
            host,
            arguments: ["update-all", "--protocol", String(remoteControlProtocolVersion)],
            onProgress: onProgress
        )
    }

    public func sshArguments(for host: RemoteHost, remoteArguments: [String]) -> [String] {
        [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "--",
            host.destination,
            ([Self.controlExecutable] + remoteArguments).map(Self.shellQuote).joined(separator: " "),
        ]
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func run(
        _ host: RemoteHost,
        arguments: [String],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        let runner = runner
        let executable = sshExecutable
        let sshArguments = sshArguments(for: host, remoteArguments: arguments)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try runner.run(
                        executable,
                        sshArguments,
                        options: CommandRunOptions(streamsStandardOutput: false),
                        onOutput: onProgress
                    )
                    if let data = result.stdout.data(using: .utf8),
                       let response = try? JSONDecoder().decode(RemoteControlResponse.self, from: data) {
                        guard response.protocolVersion == remoteControlProtocolVersion else {
                            throw RemoteSSHError.incompatibleProtocol
                        }
                        continuation.resume(returning: response)
                    } else {
                        throw Self.error(for: result, host: host)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func error(for result: CommandResult, host: RemoteHost) -> RemoteSSHError {
        let output = (result.stderr + "\n" + result.stdout).lowercased()
        if output.contains("host key verification failed")
            || output.contains("no host key is known")
            || output.contains("remote host identification has changed") {
            return .untrustedHost(host.destination)
        }
        if output.contains("permission denied") || output.contains("authentication failed") {
            return .authenticationFailed(host.destination)
        }
        if output.contains("no such file or directory") || output.contains("not found") {
            return .missingRemotePMM
        }
        return .connectionFailed(host.destination, (result.stderr.isEmpty ? result.stdout : result.stderr).trimmed)
    }
}

public enum RemoteHostError: LocalizedError, Equatable {
    case invalidDestination

    public var errorDescription: String? {
        "Enter an SSH host or alias without options or spaces, such as mac-mini or max@server."
    }
}

public enum RemoteSSHError: LocalizedError, Equatable {
    case authenticationFailed(String)
    case connectionFailed(String, String)
    case incompatibleProtocol
    case missingRemotePMM
    case untrustedHost(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let host):
            "SSH authentication failed for \(host). Configure key or agent authentication first."
        case .connectionFailed(let host, let detail):
            detail.isEmpty ? "Could not connect to \(host) over SSH." : "Could not connect to \(host): \(detail)"
        case .incompatibleProtocol:
            "Update Package Manager Manager on the remote Mac."
        case .missingRemotePMM:
            "Package Manager Manager was not found in /Applications on the remote Mac."
        case .untrustedHost(let host):
            "The SSH host key for \(host) is not trusted. Connect with ssh in Terminal once, verify the key, and try again."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
