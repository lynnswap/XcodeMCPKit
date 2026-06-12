import Foundation
import NIOConcurrencyHelpers

final class DispatchGroupLeaveGuard: @unchecked Sendable {
    private let group: DispatchGroup
    private let didLeave = NIOLockedValueBox(false)

    init(group: DispatchGroup) {
        self.group = group
        self.group.enter()
    }

    func leaveIfNeeded() {
        let shouldLeave = didLeave.withLockedValue { didLeave in
            guard didLeave == false else { return false }
            didLeave = true
            return true
        }
        guard shouldLeave else { return }
        group.leave()
    }
}

private final class PipeCollector: @unchecked Sendable {
    private let reader: OrderedPipeReader
    private let drainGuard: DispatchGroupLeaveGuard
    private let buffer = NIOLockedValueBox(Data())
    private var task: Task<Void, Never>?

    init(fileHandle: FileHandle, drainGroup: DispatchGroup, label: String) {
        self.reader = OrderedPipeReader(fileHandle: fileHandle, label: label)
        self.drainGuard = DispatchGroupLeaveGuard(group: drainGroup)
    }

    func start() {
        reader.start()
        task = Task { [buffer, drainGuard, reader] in
            for await chunk in reader.chunks {
                buffer.withLockedValue { data in
                    data.append(chunk)
                }
            }
            drainGuard.leaveIfNeeded()
        }
    }

    func collectedData() -> Data {
        buffer.withLockedValue { $0 }
    }

    func cancel() {
        reader.stop()
        task?.cancel()
        task = nil
        drainGuard.leaveIfNeeded()
    }
}

package struct ProcessRequest: Sendable {
    package let label: String
    package let executablePath: String
    package let arguments: [String]
    package let input: String?

    package init(label: String, executablePath: String, arguments: [String], input: String?) {
        self.label = label
        self.executablePath = executablePath
        self.arguments = arguments
        self.input = input
    }
}

package struct ProcessOutput: Sendable {
    package let terminationStatus: Int32
    package let stdout: String
    package let stderr: String

    package init(terminationStatus: Int32, stdout: String, stderr: String) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

package protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput
}

package struct ProcessRunner: ProcessRunning {
    package init() {}

    package func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            let drainGroup = DispatchGroup()
            let stdoutCollector = PipeCollector(
                fileHandle: stdoutPipe.fileHandleForReading,
                drainGroup: drainGroup,
                label: "XcodeMCPProxy.ProcessRunner.stdout"
            )
            let stderrCollector = PipeCollector(
                fileHandle: stderrPipe.fileHandleForReading,
                drainGroup: drainGroup,
                label: "XcodeMCPProxy.ProcessRunner.stderr"
            )
            let didResume = NIOLockedValueBox(false)
            let resumeOnce: @Sendable (Result<ProcessOutput, Error>) -> Void = { result in
                let shouldResume = didResume.withLockedValue { didResume in
                    guard didResume == false else { return false }
                    didResume = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            process.executableURL = URL(fileURLWithPath: request.executablePath)
            process.arguments = request.arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if request.input != nil {
                process.standardInput = stdinPipe
            }
            stdoutCollector.start()
            stderrCollector.start()

            process.terminationHandler = { process in
                DispatchQueue.global().async {
                    drainGroup.wait()
                    let output = ProcessOutput(
                        terminationStatus: process.terminationStatus,
                        stdout: String(decoding: stdoutCollector.collectedData(), as: UTF8.self),
                        stderr: String(decoding: stderrCollector.collectedData(), as: UTF8.self)
                    )
                    resumeOnce(.success(output))
                }
            }

            do {
                try process.run()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                if let input = request.input {
                    if let inputData = input.data(using: .utf8) {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
                    }
                    try stdinPipe.fileHandleForWriting.close()
                }
            } catch {
                process.terminationHandler = nil
                if process.isRunning {
                    process.terminate()
                }
                stdoutCollector.cancel()
                stderrCollector.cancel()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                try? stdinPipe.fileHandleForWriting.close()
                resumeOnce(.failure(error))
            }
        }
    }
}
