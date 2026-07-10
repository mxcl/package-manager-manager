import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
}

public struct CommandRunOptions: Sendable, Equatable {
    public var terminal: Bool
    public var environment: [String: String]

    public init(terminal: Bool = false, environment: [String: String] = [:]) {
        self.terminal = terminal
        self.environment = environment
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult
}

public extension CommandRunning {
    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        try run(executable, arguments)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions
    ) throws -> CommandResult {
        try run(executable, arguments, options: options, onOutput: nil)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, options: CommandRunOptions(), onOutput: nil)
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        if options.terminal {
            return try runInTerminal(executable, arguments, options: options, onOutput: onOutput)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !options.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(options.environment) { _, new in new }
        }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let stdout = AsyncPipeReader(output, onOutput: onOutput)
        let stderr = AsyncPipeReader(error, onOutput: onOutput)
        stdout.start()
        stderr.start()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(data: stdout.data(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.data(), encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private func runInTerminal(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(terminalEnvironment(options.environment)) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        try process.run()
        try? slaveHandle.close()

        let output = AsyncFileHandleReader(masterHandle, onOutput: onOutput)
        output.start()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(data: output.data(), encoding: .utf8) ?? "",
            stderr: "",
            status: process.terminationStatus
        )
    }

    private func terminalEnvironment(_ overrides: [String: String]) -> [String: String] {
        [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "CLICOLOR_FORCE": "1",
            "FORCE_COLOR": "3",
            "HOMEBREW_COLOR": "1",
            "COLUMNS": "80",
            "LINES": "24",
        ].merging(overrides) { _, new in new }
    }
}

private final class AsyncPipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private let onOutput: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var chunks = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe, onOutput: (@Sendable (String) -> Void)? = nil) {
        self.pipe = pipe
        self.onOutput = onOutput
    }

    func start() {
        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            var decoder = IncrementalUTF8Decoder()
            while true {
                let chunk = self.pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                let text = decoder.decode(chunk)
                if !text.isEmpty {
                    self.onOutput?(text)
                }
            }
            let finalText = decoder.finish()
            if !finalText.isEmpty {
                self.onOutput?(finalText)
            }
            self.lock.lock()
            self.chunks = data
            self.lock.unlock()
            self.done.signal()
        }
    }

    func data() -> Data {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

private final class AsyncFileHandleReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onOutput: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var chunks = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle, onOutput: (@Sendable (String) -> Void)? = nil) {
        self.handle = handle
        self.onOutput = onOutput
    }

    func start() {
        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            var decoder = IncrementalUTF8Decoder()
            while true {
                let chunk = self.handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                let text = decoder.decode(chunk)
                if !text.isEmpty {
                    self.onOutput?(text)
                }
            }
            let finalText = decoder.finish()
            if !finalText.isEmpty {
                self.onOutput?(finalText)
            }
            self.lock.lock()
            self.chunks = data
            self.lock.unlock()
            self.done.signal()
        }
    }

    func data() -> Data {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

struct IncrementalUTF8Decoder {
    private var pending = Data()

    mutating func decode(_ chunk: Data) -> String {
        var data = pending
        data.append(chunk)
        let suffixLength = incompleteSuffixLength(in: data)
        pending = suffixLength == 0 ? Data() : Data(data.suffix(suffixLength))
        return String(decoding: data.dropLast(suffixLength), as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    private func incompleteSuffixLength(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let bytes = [UInt8](data)
        let lowerBound = max(0, bytes.count - 4)
        for index in stride(from: bytes.count - 1, through: lowerBound, by: -1) {
            let byte = bytes[index]
            guard byte & 0xC0 != 0x80 else { continue }
            let expectedLength: Int
            switch byte {
            case 0xC2...0xDF: expectedLength = 2
            case 0xE0...0xEF: expectedLength = 3
            case 0xF0...0xF4: expectedLength = 4
            default: return 0
            }
            let availableLength = bytes.count - index
            return availableLength < expectedLength ? availableLength : 0
        }
        return 0
    }
}

public func firstExecutable(named name: String, extraPaths: [String] = []) -> String? {
    let pathParts = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    let candidates = (extraPaths + pathParts).map { "\($0)/\(name)" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
