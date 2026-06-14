import Foundation
import ProxyCore
import ProxyMCP

package enum UpstreamEvent: Sendable {
    case message(Data)
    case stderr(String)
    case stdoutProtocolViolation(StdioFramerProtocolViolation)
    case stdoutBufferSize(Int)
    case exit(Int32)
}

package enum UpstreamUnavailableReason: Sendable, Equatable {
    case notStarted
    case startFailed
    case terminated
    case shuttingDown
}

/// Why a send did not reach the upstream. Backpressure is the only case
/// that should count against the upstream's health; an unavailable slot is
/// already handled by the exit/quarantine machinery.
package enum UpstreamSendResult: Sendable, Equatable {
    case accepted
    case backpressure
    case unavailable(UpstreamUnavailableReason)
}

package protocol UpstreamSession: AnyObject, Sendable {
    var events: AsyncStream<UpstreamEvent> { get }
    func send(_ data: Data) async -> UpstreamSendResult
    func stop() async
}

package protocol UpstreamSessionFactory: Sendable {
    func startSession() async throws -> any UpstreamSession
}

package protocol UpstreamSlotControlling: Sendable {
    var events: AsyncStream<UpstreamEvent> { get }
    func start() async
    func stop() async
    func send(_ data: Data) async -> UpstreamSendResult
}
