import Foundation

/// Runs a short helper tool (`tar`, `softwareupdate`) and waits for it without blocking a thread.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var output: String
    }

    struct Failure: Error, CustomStringConvertible {
        var tool: String
        var status: Int32
        var output: String
        var description: String { "\(tool) failed (\(status)): \(output)" }
    }

    /// Combined stdout and stderr, so a failure message has whatever the tool said.
    /// - Parameters:
    ///   - environment: replaces the inherited environment entirely when given.
    ///   - timeout: the tool is killed after this many seconds. For anything that talks to a running Wine program,
    ///     which can hang for good: `steam.exe -shutdown` waited forever on a Steam stuck at start.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            // Read on a background queue so a chatty tool can't fill the pipe and stall.
            let collected = Collected()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                collected.append(handle.availableData)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Output(status: process.terminationStatus, output: collected.text))
            }
            do {
                try process.run()
                if let timeout {
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    static func check(_ executable: String, _ arguments: [String],
                      environment: [String: String]? = nil) async throws {
        let result = try await run(executable, arguments, environment: environment)
        guard result.status == 0 else {
            throw Failure(tool: URL(filePath: executable).lastPathComponent, status: result.status,
                          output: String(result.output.suffix(2000)))
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.withLock { data.append(chunk) }
        }

        var text: String {
            lock.withLock { String(bytes: data, encoding: .utf8) ?? "(not text output)" }
        }
    }
}
