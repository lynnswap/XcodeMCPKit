import Foundation
import NIOConcurrencyHelpers

struct SessionRecord: Sendable {
    let context: SessionContext
    let generation: UInt64
    var isInitialized: Bool
    var negotiatedProtocolVersion: String?
}

final class SessionRegistry: Sendable {
    private struct State: Sendable {
        var sessions: [String: SessionRecord] = [:]
        var nextGeneration: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyRuntimeConfiguration
    private let notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)?
    private let sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)?

    init(
        configuration: ProxyRuntimeConfiguration,
        notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)? = nil,
        sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)? = nil
    ) {
        self.config = configuration
        self.notificationSink = notificationSink
        self.sessionClosedSink = sessionClosedSink
    }

    func session(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing.context
            }
            let context: SessionContext
            if let notificationSink {
                context = SessionContext(
                    id: id,
                    config: config,
                    notificationSink: { [id] data in
                        notificationSink(id, data)
                    }
                )
            } else {
                context = SessionContext(id: id, config: config)
            }
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

    func hasSession(id: String) -> Bool {
        state.withLockedValue { $0.sessions[id] != nil }
    }

    func removeSession(id: String) -> SessionContext? {
        let context = state.withLockedValue { $0.sessions.removeValue(forKey: id)?.context }
        if context != nil {
            sessionClosedSink?(id)
        }
        return context
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

    func initializedNotificationTargets() -> [SessionContext] {
        state.withLockedValue { state in
            state.sessions.values.compactMap { record in
                record.isInitialized ? record.context : nil
            }
        }
    }

    func markInitialized(
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
        let sessions = state.withLockedValue { state -> [(String, SessionContext)] in
            let sessions = state.sessions.map { ($0.key, $0.value.context) }.sorted {
                $0.0 < $1.0
            }
            state.sessions.removeAll()
            return sessions
        }
        for (id, _) in sessions {
            sessionClosedSink?(id)
        }
        return sessions.map(\.1)
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
