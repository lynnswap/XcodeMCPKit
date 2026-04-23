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

package enum UpstreamSendResult: Sendable {
    case accepted
    case overloaded
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
