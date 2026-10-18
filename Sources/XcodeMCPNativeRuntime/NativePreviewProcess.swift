import Foundation
import Darwin
import Synchronization

@MainActor
final class NativePreviewProcess {
    nonisolated struct TerminationFailure: Error, CustomStringConvertible {
        let process: Process
        let executable: String
        let errnoValue: Int32

        var processIdentifier: Int32 { process.processIdentifier }

        var description: String {
            let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errnoValue))
            return "Could not send SIGKILL to \(executable) (PID \(processIdentifier)): \(failure); the process may still be running"
        }
    }

    private let installation: NativeXcodeInstallation
    private let artifacts: URL
    private let sendSignal: @Sendable (Int32, Int32) -> Int32

    init(installation: NativeXcodeInstallation, artifacts: URL,
         sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }) {
        self.installation = installation
        self.artifacts = artifacts
        self.sendSignal = sendSignal
    }

    func run(_ executable: String, _ arguments: [String], environment launchEnvironment: [String: String] = [:],
             directory: URL? = nil, outputLog: URL? = nil) async throws -> String {
        try Task.checkCancellation()
        let logURL = outputLog ?? artifacts.appendingPathComponent("process-\(UUID().uuidString).log")
        try Data().write(to: logURL)
        let errorURL = logURL.appendingPathExtension("stderr")
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: logURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close() }
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // Child tools and Simulator apps use their SDK libraries, rather than
        // the framework search paths needed by this macOS native host.
        for key in environment.keys where key.hasPrefix("DYLD_") || key.hasPrefix("SIMCTL_CHILD_") {
            environment[key] = nil
        }
        environment["DEVELOPER_DIR"] = installation.developerDirectory.path
        environment.merge(launchEnvironment, uniquingKeysWith: { _, new in new })
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        let sendSignal = sendSignal
        let cancellation = Mutex((cancelled: false, continuation: Optional<CheckedContinuation<Int32, any Error>>.none))
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { [process] completed in
                    defer { process.terminationHandler = nil }
                    let pending = cancellation.withLock { state in
                        let pending = state.continuation
                        state.continuation = nil
                        return pending
                    }
                    pending?.resume(returning: completed.terminationStatus)
                }
                do {
                    try cancellation.withLock { state in
                        state.continuation = continuation
                        guard !state.cancelled else { throw CancellationError() }
                        try process.run()
                    }
                }
                catch {
                    process.terminationHandler = nil
                    let pending = cancellation.withLock { state in
                        let pending = state.continuation
                        state.continuation = nil
                        return pending
                    }
                    pending?.resume(throwing: error)
                }
            }
        } onCancel: {
            let running = cancellation.withLock { state in
                state.cancelled = true
                return process.isRunning
            }
            if running {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    let pending = cancellation.withLock { state -> (CheckedContinuation<Int32, any Error>, TerminationFailure)? in
                        guard process.isRunning, sendSignal(process.processIdentifier, SIGKILL) != 0 else { return nil }
                        let failure = errno
                        guard failure != ESRCH, let continuation = state.continuation else { return nil }
                        state.continuation = nil
                        return (continuation, TerminationFailure(process: process, executable: executable, errnoValue: failure))
                    }
                    if let (continuation, failure) = pending {
                        continuation.resume(throwing: failure)
                    }
                }
            }
        }
        let text = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        try Task.checkCancellation()
        guard status == 0 else {
            let diagnostic = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            throw NativeRuntimeError.invocation("\(URL(filePath: executable).lastPathComponent) exited with \(status): \(text)\(diagnostic)")
        }
        return text
    }

    func xcrun(_ arguments: [String], environment: [String: String] = [:]) async throws -> String {
        try await run("/usr/bin/xcrun", arguments, environment: environment)
    }
}
