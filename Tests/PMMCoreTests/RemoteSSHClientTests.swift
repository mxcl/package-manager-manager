import Foundation
import Testing
@testable import PMMCore

@Test func remoteHostValidatesAndNormalizesConfiguration() throws {
    let host = try RemoteHost(name: "  Build Mac  ", destination: "  max@mac-mini  ")
    #expect(host.name == "Build Mac")
    #expect(host.destination == "max@mac-mini")
    #expect(host.displayName == "Build Mac")
    #expect(try RemoteHost(destination: "pangolin.local").displayName == "Pangolin")
    #expect(try RemoteHost(destination: "max@pangolin.local").displayName == "Max@pangolin")
    #expect(throws: RemoteHostError.invalidDestination) { try RemoteHost(destination: "-oProxyCommand=bad") }
    #expect(throws: RemoteHostError.invalidDestination) { try RemoteHost(destination: "host; touch /tmp/bad") }
}

@Test func remoteSSHArgumentsUseStrictNonInteractiveSSHAndQuoteEveryRemoteArgument() throws {
    let host = try RemoteHost(destination: "mac-mini")
    let arguments = RemoteSSHClient().sshArguments(
        for: host,
        remoteArguments: ["update", "--id", "npm:it's-a-package"]
    )
    #expect(arguments.contains("BatchMode=yes"))
    #expect(arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("--"))
    #expect(arguments[arguments.count - 2] == "mac-mini")
    #expect(arguments.last == "'/Applications/Package Manager Manager.app/Contents/Helpers/pmmctl' 'remote' 'update' '--id' 'npm:it'\"'\"'s-a-package'")
}

@Test @MainActor func remoteSSHExecutionLeavesMainThreadAndDecodesResponse() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "progress",
        status: 0
    ))
    let host = try RemoteHost(destination: "mac-mini")
    let decoded = try await RemoteSSHClient(runner: runner).inventory(on: host)

    #expect(decoded == response)
    #expect(runner.ranOnMainThread == false)
    #expect(runner.options?.streamsStandardOutput == false)
}

@Test func remoteSSHDecodesPartialFailureResponseDespiteNonzeroStatus() async throws {
    let response = RemoteControlResponse(
        inventory: PackageInventory(packages: []),
        failures: [RemoteControlFailure(message: "one package failed")]
    )
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "failure detail",
        status: 1
    ))
    let decoded = try await RemoteSSHClient(runner: runner).inventory(on: try RemoteHost(destination: "mac-mini"))
    #expect(decoded == response)
}

@Test func remoteSSHExplainsUntrustedHostKeys() async {
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: "",
        stderr: "Host key verification failed.",
        status: 255
    ))
    await #expect(throws: RemoteSSHError.untrustedHost("mac-mini")) {
        try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "mac-mini"))
    }
}

private final class RecordingRemoteRunner: CommandRunning, @unchecked Sendable {
    private let result: CommandResult
    private let lock = NSLock()
    private var _ranOnMainThread: Bool?
    private var _options: CommandRunOptions?

    init(result: CommandResult) {
        self.result = result
    }

    var ranOnMainThread: Bool? { lock.withLock { _ranOnMainThread } }
    var options: CommandRunOptions? { lock.withLock { _options } }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult { result }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        lock.withLock {
            _ranOnMainThread = Thread.isMainThread
            _options = options
        }
        onOutput?(result.stderr)
        return result
    }
}
