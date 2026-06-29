import Foundation

package enum XcodeMCPTransportEvent: Sendable {
    case message(Data)
    case closed(String?)
}

package protocol XcodeMCPTransport: Sendable {
    var events: AsyncStream<XcodeMCPTransportEvent> { get }

    func send(_ data: Data) async throws
    func close() async
}

package final class UpstreamProcessXcodeMCPTransport: XcodeMCPTransport {
    package nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let session: any UpstreamSession
    private let bridgeTask: Task<Void, Never>

    package static func start(config: UpstreamProcess.Config) async throws -> UpstreamProcessXcodeMCPTransport {
        let session = try await UpstreamProcess(configuration: config).startSession()
        return UpstreamProcessXcodeMCPTransport(session: session)
    }

    package static func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        maxQueuedWriteBytes: Int
    ) async throws -> UpstreamProcessXcodeMCPTransport {
        try await start(
            config: UpstreamProcess.Config(
                command: command,
                args: arguments,
                environment: environment,
                maxQueuedWriteBytes: maxQueuedWriteBytes
            )
        )
    }

    private init(session: any UpstreamSession) {
        self.session = session
        let sessionEvents = session.events
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.bridgeTask = Task {
            for await event in sessionEvents {
                switch event {
                case .message(let data):
                    stream.continuation.yield(.message(data))
                case .stderr, .stdoutBufferSize:
                    continue
                case .stdoutProtocolViolation(let violation):
                    stream.continuation.yield(.closed("protocol violation: \(violation.reason.rawValue)"))
                    stream.continuation.finish()
                    return
                case .exit(let status):
                    stream.continuation.yield(.closed("process exited with status \(status)"))
                    stream.continuation.finish()
                    return
                }
            }
            stream.continuation.yield(.closed(nil))
            stream.continuation.finish()
        }
    }

    deinit {
        bridgeTask.cancel()
    }

    package func send(_ data: Data) async throws {
        switch await session.send(data) {
        case .accepted:
            return
        case .backpressure:
            throw MCPBridgeRuntimeError.transportUnavailable("mcpbridge write queue is full")
        case .unavailable(let reason):
            throw MCPBridgeRuntimeError.transportUnavailable("mcpbridge is unavailable: \(reason)")
        }
    }

    package func close() async {
        bridgeTask.cancel()
        await session.stop()
    }
}
