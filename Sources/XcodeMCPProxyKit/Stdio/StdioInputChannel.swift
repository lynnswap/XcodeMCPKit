import Darwin
import Dispatch
import Foundation
import XcodeMCPKit

protocol StdioInputReading: Sendable {
    func read() async throws -> Data?
    func stop()
    func waitUntilStopped() async
}

private struct StdioInputReadError: Error, CustomStringConvertible, Sendable {
    let code: Int32

    var description: String {
        "STDIO input read failed with errno \(code)"
    }
}

final class StdioInputChannel: StdioInputReading, @unchecked Sendable {
    private enum Lifecycle {
        case open
        case endOfFile
        case failed(StdioInputReadError)
        case stopped
    }

    private static let maxReadOperationByteCount = 64 * 1024

    private let callbackQueue = DispatchQueue(label: "XcodeMCPProxy.StdioInputChannel.io")
    private let channel: DispatchIO
    private let terminal: AsyncTerminalSignal

    // Access is confined to callbackQueue.
    private var lifecycle: Lifecycle = .open
    private var bufferedInput = Data()
    private var pendingRead: CheckedContinuation<Data?, any Error>?
    private var isReadOperationActive = false
    private var activeOperationByteCount = 0

    init(handle: FileHandle) {
        let descriptor = dup(handle.fileDescriptor)
        precondition(descriptor >= 0, "STDIO input FileHandle must be open")

        let terminal = AsyncTerminalSignal()
        self.terminal = terminal
        self.channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: callbackQueue
        ) { _ in
            _ = Darwin.close(descriptor)
            try? handle.close()
            terminal.signal()
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: Self.maxReadOperationByteCount)
    }

    func read() async throws -> Data? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                callbackQueue.async { [self] in
                    registerRead(continuation)
                }
            }
        } onCancel: {
            stop()
        }
    }

    func stop() {
        callbackQueue.async { [self] in
            guard case .open = lifecycle else { return }
            lifecycle = .stopped
            bufferedInput.removeAll()
            let continuation = pendingRead
            pendingRead = nil
            channel.close(flags: .stop)
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitUntilStopped() async {
        await terminal.wait()
    }

    private func registerRead(
        _ continuation: CheckedContinuation<Data?, any Error>
    ) {
        precondition(pendingRead == nil, "STDIO input supports one consumer")

        if bufferedInput.isEmpty == false {
            let chunk = bufferedInput
            bufferedInput = Data()
            continuation.resume(returning: chunk)
            return
        }

        switch lifecycle {
        case .open:
            pendingRead = continuation
            startReadOperationIfNeeded()
        case .endOfFile:
            continuation.resume(returning: nil)
        case .failed(let error):
            continuation.resume(throwing: error)
        case .stopped:
            continuation.resume(throwing: CancellationError())
        }
    }

    private func startReadOperationIfNeeded() {
        guard
            case .open = lifecycle,
            pendingRead != nil,
            bufferedInput.isEmpty,
            isReadOperationActive == false
        else {
            return
        }

        isReadOperationActive = true
        activeOperationByteCount = 0
        channel.read(
            offset: 0,
            length: Self.maxReadOperationByteCount,
            queue: callbackQueue
        ) { [weak self] done, dispatchData, error in
            self?.receiveReadResult(
                done: done,
                data: dispatchData.map { Data($0) },
                error: error
            )
        }
    }

    private func receiveReadResult(
        done: Bool,
        data: Data?,
        error: Int32
    ) {
        guard case .open = lifecycle else { return }

        let chunk = data ?? Data()
        if error != 0 {
            isReadOperationActive = false
            finishWithError(StdioInputReadError(code: error))
            return
        }

        if chunk.isEmpty == false {
            activeOperationByteCount += chunk.count
            precondition(
                activeOperationByteCount <= Self.maxReadOperationByteCount,
                "DispatchIO exceeded the requested STDIO input byte count"
            )
            deliverOrBuffer(chunk)
        }

        guard done else { return }
        isReadOperationActive = false

        if chunk.isEmpty {
            finishAtEndOfFile()
        } else {
            startReadOperationIfNeeded()
        }
    }

    private func deliverOrBuffer(_ chunk: Data) {
        if let continuation = pendingRead {
            pendingRead = nil
            continuation.resume(returning: chunk)
        } else {
            bufferedInput.append(chunk)
            precondition(
                bufferedInput.count <= Self.maxReadOperationByteCount,
                "STDIO input buffer exceeded its bounded read operation"
            )
        }
    }

    private func finishAtEndOfFile() {
        lifecycle = .endOfFile
        channel.close()
        resumeTerminalReadIfPossible()
    }

    private func finishWithError(_ error: StdioInputReadError) {
        lifecycle = .failed(error)
        bufferedInput.removeAll()
        channel.close(flags: .stop)
        resumeTerminalReadIfPossible()
    }

    private func resumeTerminalReadIfPossible() {
        guard bufferedInput.isEmpty, let continuation = pendingRead else { return }
        pendingRead = nil
        switch lifecycle {
        case .endOfFile:
            continuation.resume(returning: nil)
        case .failed(let error):
            continuation.resume(throwing: error)
        case .stopped:
            continuation.resume(throwing: CancellationError())
        case .open:
            preconditionFailure("STDIO input terminal read resumed while open")
        }
    }
}
