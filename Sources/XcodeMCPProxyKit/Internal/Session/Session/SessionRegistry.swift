import Foundation
import NIOConcurrencyHelpers

struct SessionRecord: Sendable {
    let context: SessionContext
    let generation: UInt64
    var isInitialized: Bool
    var negotiatedProtocolVersion: String?
    var buffersUnmappedNotificationsUntilClientConnects: Bool
}

final class SessionRegistry: Sendable {
    private struct State: Sendable {
        var sessions: [String: SessionRecord] = [:]
        var nextGeneration: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig

    init(config: ProxyConfig) {
        self.config = config
    }

    func session(id: String) -> SessionContext {
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
                negotiatedProtocolVersion: nil,
                buffersUnmappedNotificationsUntilClientConnects: false
            )
            return context
        }
    }

    func hasSession(id: String) -> Bool {
        state.withLockedValue { $0.sessions[id] != nil }
    }

    func removeSession(id: String) -> SessionContext? {
        state.withLockedValue { $0.sessions.removeValue(forKey: id)?.context }
    }

    func generation(of sessionID: String) -> UInt64? {
        state.withLockedValue { $0.sessions[sessionID]?.generation }
    }

    func contextIfPresent(id sessionID: String) -> SessionContext? {
        state.withLockedValue { $0.sessions[sessionID]?.context }
    }

    func sessionStillMatchesPendingInitialize(
        sessionID: String,
        sessionGeneration: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionID] else { return false }
            return record.generation == sessionGeneration
        }
    }

    func sessionIDs() -> [String] {
        state.withLockedValue { Array($0.sessions.keys).sorted() }
    }

    func activeNotificationTargets() -> [SessionContext] {
        state.withLockedValue { state in
            state.sessions.values.compactMap { record in
                record.context.notificationHub.hasClients ? record.context : nil
            }
        }
    }

    func pendingNotificationClientTargets() -> [SessionContext] {
        state.withLockedValue { state in
            state.sessions.values.compactMap { record in
                record.isInitialized && record.buffersUnmappedNotificationsUntilClientConnects
                    ? record.context
                    : nil
            }
        }
    }

    func markInitialized(
        id sessionID: String,
        negotiatedProtocolVersion: String?,
        buffersUnmappedNotificationsUntilClientConnects: Bool = false
    ) {
        state.withLockedValue { state in
            guard var record = state.sessions[sessionID] else { return }
            record.isInitialized = true
            record.negotiatedProtocolVersion = negotiatedProtocolVersion
            record.buffersUnmappedNotificationsUntilClientConnects =
                buffersUnmappedNotificationsUntilClientConnects
            state.sessions[sessionID] = record
        }
    }

    func markNotificationClientConnected(id sessionID: String) {
        state.withLockedValue { state in
            guard var record = state.sessions[sessionID] else { return }
            record.buffersUnmappedNotificationsUntilClientConnects = false
            state.sessions[sessionID] = record
        }
    }

    func isInitialized(id sessionID: String) -> Bool {
        state.withLockedValue { state in
            state.sessions[sessionID]?.isInitialized ?? false
        }
    }

    func negotiatedProtocolVersion(id sessionID: String) -> String? {
        state.withLockedValue { state in
            state.sessions[sessionID]?.negotiatedProtocolVersion
        }
    }

    func removeAllSessions() -> [SessionContext] {
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
