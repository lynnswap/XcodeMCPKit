import Foundation

package enum Upstream {}

extension Upstream {
    package enum Event: Sendable {
        case message(Data)
        case stderr(String)
        case stdoutProtocolViolation(StdioFramer.ProtocolViolation)
        case stdoutBufferSize(Int)
        case exit(Int32)
    }

    package enum UnavailableReason: Sendable, Equatable {
        case notStarted
        case startFailed
        case terminated
        case shuttingDown
    }

    /// Why a send did not reach the upstream. Backpressure is the only case
    /// that should count against the upstream's health; an unavailable slot is
    /// already handled by the exit/quarantine machinery.
    package enum SendResult: Sendable, Equatable {
        case accepted
        case backpressure
        case unavailable(Upstream.UnavailableReason)
    }
}

package protocol UpstreamSession: AnyObject, Sendable {
    var events: AsyncStream<Upstream.Event> { get }
    /// Sends a synchronous best-effort stop signal to the owned process I/O.
    /// Completion remains the responsibility of ``stop()``.
    nonisolated func cancel()
    func send(_ data: Data) async -> Upstream.SendResult
    func stop() async
}

package protocol UpstreamSessionFactory: Sendable {
    func startSession() async throws -> any UpstreamSession
}

package protocol UpstreamSlotControlling: Sendable {
    var events: AsyncStream<Upstream.Event> { get }
    func start() async
    func stop() async
    func send(_ data: Data) async -> Upstream.SendResult
}
