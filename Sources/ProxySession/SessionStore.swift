import Foundation
import NIOConcurrencyHelpers
import ProxyCore

package struct SessionRecord: Sendable {
    package let context: SessionContext
    package let generation: UInt64
}

package final class SessionRegistry: Sendable {
    private struct State: Sendable {
        var sessions: [String: SessionRecord] = [:]
        var nextGeneration: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig

    package init(config: ProxyConfig) {
        self.config = config
    }

    package func session(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing.context
            }
            let context = SessionContext(id: id, config: config)
            state.nextGeneration &+= 1
            state.sessions[id] = SessionRecord(
                context: context,
                generation: state.nextGeneration
            )
            return context
        }
    }

    package func hasSession(id: String) -> Bool {
        state.withLockedValue { $0.sessions[id] != nil }
    }

    package func removeSession(id: String) -> SessionContext? {
        state.withLockedValue { $0.sessions.removeValue(forKey: id)?.context }
    }

    package func generation(of sessionID: String) -> UInt64? {
        state.withLockedValue { $0.sessions[sessionID]?.generation }
    }

    package func contextIfPresent(id sessionID: String) -> SessionContext? {
        state.withLockedValue { $0.sessions[sessionID]?.context }
    }

    package func sessionStillMatchesPendingInitialize(
        sessionID: String,
        sessionGeneration: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionID] else { return false }
            return record.generation == sessionGeneration
        }
    }

    package func sessionIDs() -> [String] {
        state.withLockedValue { Array($0.sessions.keys).sorted() }
    }

    package func activeNotificationTargets() -> [SessionContext] {
        state.withLockedValue { state in
            state.sessions.values.compactMap { record in
                record.context.notificationHub.hasClients ? record.context : nil
            }
        }
    }

    package func removeAllSessions() -> [SessionContext] {
        state.withLockedValue { state in
            let contexts = state.sessions.values.map(\.context)
            state.sessions.removeAll()
            return contexts
        }
    }

    func testSnapshot(id: String) -> RuntimeCoordinator.TestSnapshot.Session? {
        state.withLockedValue { state in
            guard let record = state.sessions[id] else { return nil }
            return RuntimeCoordinator.TestSnapshot.Session(
                generation: record.generation,
                pinnedUpstreamIndex: nil,
                initializeUpstreamIndex: nil,
                preferInitializeUpstreamOnNextPin: false,
                didReceiveInitializeUpstreamMessage: false
            )
        }
    }
}
