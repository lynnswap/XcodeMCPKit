import Foundation
import NIOConcurrencyHelpers
import ProxyCore

package struct SessionRecord: Sendable {
    package let context: SessionContext
    package let generation: UInt64
    package var isInitialized: Bool
    package var negotiatedProtocolVersion: String?
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
                generation: state.nextGeneration,
                isInitialized: false,
                negotiatedProtocolVersion: nil
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

    package func markInitialized(
        id sessionID: String,
        negotiatedProtocolVersion: String?
    ) {
        state.withLockedValue { state in
            guard var record = state.sessions[sessionID] else { return }
            record.isInitialized = true
            record.negotiatedProtocolVersion = negotiatedProtocolVersion
            state.sessions[sessionID] = record
        }
    }

    package func isInitialized(id sessionID: String) -> Bool {
        state.withLockedValue { state in
            state.sessions[sessionID]?.isInitialized ?? false
        }
    }

    package func negotiatedProtocolVersion(id sessionID: String) -> String? {
        state.withLockedValue { state in
            state.sessions[sessionID]?.negotiatedProtocolVersion
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
                generation: record.generation
            )
        }
    }
}
