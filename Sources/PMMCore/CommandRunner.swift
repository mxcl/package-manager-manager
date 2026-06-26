import Foundation

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }
}

public func firstExecutable(named name: String, extraPaths: [String] = []) -> String? {
    let pathParts = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    let candidates = (extraPaths + pathParts).map { "\($0)/\(name)" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
