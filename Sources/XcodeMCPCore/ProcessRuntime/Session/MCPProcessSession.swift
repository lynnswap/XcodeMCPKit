import Foundation
import XcodeMCPWire

package enum MCPProcess {}

extension MCPProcess {
    package enum Event: Sendable {
        case message(Data)
        case stderr(String)
        case stdoutProtocolViolation(StdioFramer.ProtocolViolation)
        case stdoutBufferSize(Int)
        case stdoutClosed
        case exit(Int32)
    }

    package enum UnavailableReason: Sendable, Equatable {
        case notStarted
        case startFailed
        case terminated
        case shuttingDown
    }

    /// Why a send did not reach the process. Backpressure is the only case
    /// that should count against the process's health; an unavailable slot is
    /// already handled by the exit/quarantine machinery.
    package enum SendResult: Sendable, Equatable {
        case accepted
        case backpressure
        case unavailable(MCPProcess.UnavailableReason)
    }
}

package protocol MCPProcessSession: AnyObject, Sendable {
    var events: AsyncStream<MCPProcess.Event> { get }
    /// Sends a synchronous best-effort stop signal to the owned process I/O.
    /// Completion remains the responsibility of ``stop()``.
    nonisolated func cancel()
    func send(_ data: Data) async -> MCPProcess.SendResult
    /// Closes MCP input and waits for process exit and output drain. Unresponsive
    /// processes are terminated after the configured shutdown grace.
    func stop() async
}

package protocol MCPProcessSessionFactory: Sendable {
    func startSession() async throws -> any MCPProcessSession
}
