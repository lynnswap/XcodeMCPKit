import Foundation
import Synchronization

@MainActor
final class NativePreviewProcess {
    private let installation: NativeXcodeInstallation
    private let artifacts: URL

    init(installation: NativeXcodeInstallation, artifacts: URL) {
        self.installation = installation
        self.artifacts = artifacts
    }

    func run(_ executable: String, _ arguments: [String], environment launchEnvironment: [String: String] = [:],
             directory: URL? = nil) async throws -> String {
        try Task.checkCancellation()
        let logURL = artifacts.appendingPathComponent("process-\(UUID().uuidString).log")
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
        let cancelled = Mutex(false)
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    try cancelled.withLock { cancelled in
                        guard !cancelled else { throw CancellationError() }
                        try process.run()
                    }
                }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            cancelled.withLock { cancelled in
                cancelled = true
                if process.isRunning { process.terminate() }
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
