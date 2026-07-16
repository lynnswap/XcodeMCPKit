import Foundation
import NIOConcurrencyHelpers

struct SessionRecord: Sendable {
    let context: SessionContext
    let generation: UInt64
    var isInitialized: Bool
    var negotiatedProtocolVersion: String?
    var isClientTransportSession: Bool
    var lastClientActivityUptimeNanoseconds: UInt64
    var activeClientRequestCount: Int
    var activeEventStreamCount: Int
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
    private let nowUptimeNanoseconds: @Sendable () -> UInt64

    init(
        configuration: ProxyRuntimeConfiguration,
        notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)? = nil,
        sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)? = nil,
        nowUptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.config = configuration
        self.notificationSink = notificationSink
        self.sessionClosedSink = sessionClosedSink
        self.nowUptimeNanoseconds = nowUptimeNanoseconds
    }

    func session(id: String) -> SessionContext {
        let now = nowUptimeNanoseconds()
        return state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing.context
            }
            let record = makeRecord(id: id, state: &state, nowUptimeNanoseconds: now)
            state.sessions[id] = record
            return record.context
        }
    }

    func sessionStateAndTouch(id: String) -> ProxyRuntimeSessionState {
        let now = nowUptimeNanoseconds()
        return state.withLockedValue { state in
            guard var record = state.sessions[id] else { return .missing }
            record.isClientTransportSession = true
            record.lastClientActivityUptimeNanoseconds = now
            state.sessions[id] = record
            guard record.isInitialized else { return .uninitialized }
            return .initialized(protocolVersion: record.negotiatedProtocolVersion)
        }
    }

    @discardableResult
    func beginClientRequest(id: String, createIfMissing: Bool) -> Bool {
        let now = nowUptimeNanoseconds()
        return state.withLockedValue { state in
            var record: SessionRecord
            if let existing = state.sessions[id] {
                record = existing
            } else {
                guard createIfMissing else { return false }
                record = makeRecord(id: id, state: &state, nowUptimeNanoseconds: now)
            }
            record.isClientTransportSession = true
            record.activeClientRequestCount += 1
            record.lastClientActivityUptimeNanoseconds = now
            state.sessions[id] = record
            return true
        }
    }

    func endClientRequest(id: String) {
        let now = nowUptimeNanoseconds()
        state.withLockedValue { state in
            guard var record = state.sessions[id] else { return }
            precondition(
                record.activeClientRequestCount > 0,
                "client request activity ended without a matching begin"
            )
            record.activeClientRequestCount -= 1
            record.lastClientActivityUptimeNanoseconds = now
            state.sessions[id] = record
        }
    }

    @discardableResult
    func openEventStream(id: String) -> Bool {
        let now = nowUptimeNanoseconds()
        return state.withLockedValue { state in
            guard var record = state.sessions[id] else { return false }
            record.isClientTransportSession = true
            record.activeEventStreamCount += 1
            record.lastClientActivityUptimeNanoseconds = now
            state.sessions[id] = record
            return true
        }
    }

    func closeEventStream(id: String) {
        let now = nowUptimeNanoseconds()
        state.withLockedValue { state in
            guard var record = state.sessions[id] else { return }
            precondition(
                record.activeEventStreamCount > 0,
                "event stream activity ended without a matching open"
            )
            record.activeEventStreamCount -= 1
            record.lastClientActivityUptimeNanoseconds = now
            state.sessions[id] = record
        }
    }

    func removeInactiveSessions(inactiveForNanoseconds: UInt64) -> [String] {
        precondition(inactiveForNanoseconds > 0)
        let now = nowUptimeNanoseconds()
        let removedSessionIDs = state.withLockedValue { state -> [String] in
            let expiredSessionIDs = state.sessions.compactMap { entry -> String? in
                let (sessionID, record) = entry
                guard record.isClientTransportSession,
                    record.activeClientRequestCount == 0,
                    record.activeEventStreamCount == 0,
                    now >= record.lastClientActivityUptimeNanoseconds,
                    now - record.lastClientActivityUptimeNanoseconds >= inactiveForNanoseconds
                else {
                    return nil
                }
                return sessionID
            }.sorted()
            for sessionID in expiredSessionIDs {
                state.sessions.removeValue(forKey: sessionID)
            }
            return expiredSessionIDs
        }
        for sessionID in removedSessionIDs {
            sessionClosedSink?(sessionID)
        }
        return removedSessionIDs
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

    private func makeRecord(
        id: String,
        state: inout State,
        nowUptimeNanoseconds: UInt64
    ) -> SessionRecord {
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
        return SessionRecord(
            context: context,
            generation: state.nextGeneration,
            isInitialized: false,
            negotiatedProtocolVersion: nil,
            isClientTransportSession: false,
            lastClientActivityUptimeNanoseconds: nowUptimeNanoseconds,
            activeClientRequestCount: 0,
            activeEventStreamCount: 0
        )
    }
}
