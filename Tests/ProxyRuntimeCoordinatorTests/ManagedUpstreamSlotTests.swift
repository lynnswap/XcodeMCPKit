import Foundation
import Testing

@testable import XcodeMCPProcessRuntime
@testable import XcodeMCPProxyKit

@Suite
struct ManagedUpstreamSlotTests {
    @Test func managedUpstreamSlotClearsPendingStartWhenStartFails() async throws {
        let slot = ManagedUpstreamSlot(factory: FailingUpstreamSessionFactory())
        await slot.start()

        let first = await slot.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        let second = await slot.send(Data(#"{"jsonrpc":"2.0","id":2}"#.utf8))
        await slot.stop()

        switch first {
        case .unavailable(.startFailed), .unavailable(.notStarted):
            break
        case .accepted, .backpressure, .unavailable:
            Issue.record("send during a failed start should report unavailable")
        }
        #expect(second == .unavailable(.notStarted))
    }
}

private struct FailingUpstreamSessionFactory: UpstreamSessionFactory {
    func startSession() async throws -> any UpstreamSession {
        throw StartFailure()
    }
}

private struct StartFailure: Error {}
