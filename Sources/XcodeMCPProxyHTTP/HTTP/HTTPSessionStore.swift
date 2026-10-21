import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPProxyRuntimeContract

/// The gateway's MCP sessions. It decides when each one is created, in use, expired, and deleted,
/// and ends the runtime's side of a session when it is deleted.
final class HTTPSessionStore: Sendable {
    enum Phase: Equatable, Sendable {
        /// The session's `initialize` request has not completed.
        case initializing
        case initialized(protocolVersion: String?)
    }

    private struct Entry: Sendable {
        let session: any ProxyRuntimeSession
        var phase: Phase = .initializing
        /// Requests that use the session; the `initialize` request holds the first.
        var leases = 1
        var streams = 0
        var lastActivity: UInt64
    }

    private struct State: Sendable {
        var entries: [ProxySessionID: Entry] = [:]
        /// Runtime resets in progress, during which no session starts.
        var resetsInProgress = 0
        /// Counts the resets that have started. A session opened before a reset started must not
        /// be kept after it, since the reset may have closed its runtime side.
        var resetGeneration: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())
    private let runtime: any ProxyRuntimeServing
    let delivery: HTTPEventDeliveryStore
    private let uptimeNanoseconds: @Sendable () -> UInt64

    init(runtime: any ProxyRuntimeServing, delivery: HTTPEventDeliveryStore,
         uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.runtime = runtime
        self.delivery = delivery
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// Opens a session for an `initialize` request, which holds it until ``release(_:)``.
    func create(_ id: ProxySessionID) throws -> any ProxyRuntimeSession {
        let generation = state.withLockedValue { $0.resetsInProgress == 0 ? $0.resetGeneration : nil }
        guard let generation else { throw ProxyRuntimeUnavailable() }
        delivery.register(id)
        let session: any ProxyRuntimeSession
        do {
            session = try runtime.openSession(id) { [delivery] data in delivery.deliver(data, to: id) }
        } catch {
            delivery.remove(id)
            throw error
        }
        let created = state.withLockedValue { state in
            guard state.resetGeneration == generation else { return false }
            state.entries[id] = Entry(session: session, lastActivity: uptimeNanoseconds())
            return true
        }
        guard created else {
            delivery.remove(id)
            session.close()
            throw ProxyRuntimeUnavailable()
        }
        return session
    }

    func phase(of id: ProxySessionID) -> Phase? {
        state.withLockedValue { $0.entries[id]?.phase }
    }

    func markInitialized(_ id: ProxySessionID, protocolVersion: String?) {
        state.withLockedValue { $0.entries[id]?.phase = .initialized(protocolVersion: protocolVersion) }
    }

    /// Lets one request use the session until ``release(_:)``. Returns `nil` for an unknown session,
    /// before the request is processed.
    func acquire(_ id: ProxySessionID) -> (any ProxyRuntimeSession)? {
        state.withLockedValue { state in
            guard var entry = state.entries[id] else { return nil }
            entry.leases += 1
            entry.lastActivity = uptimeNanoseconds()
            state.entries[id] = entry
            return entry.session
        }
    }

    func release(_ id: ProxySessionID) {
        state.withLockedValue { state in
            state.entries[id]?.leases -= 1
            state.entries[id]?.lastActivity = uptimeNanoseconds()
        }
    }

    /// Attaches a client's event stream. Returns `false` for an unknown session.
    func openStream(_ id: ProxySessionID, channel: Channel) -> Bool {
        let opened = state.withLockedValue { state in
            guard state.entries[id] != nil else { return false }
            state.entries[id]?.streams += 1
            state.entries[id]?.lastActivity = uptimeNanoseconds()
            return true
        }
        guard opened, delivery.open(sessionID: id, channel: channel) else {
            if opened { closeStream(id, channel: channel) }
            return false
        }
        return true
    }

    func closeStream(_ id: ProxySessionID, channel: Channel) {
        delivery.close(sessionID: id, channel: channel)
        state.withLockedValue { state in
            state.entries[id]?.streams -= 1
            state.entries[id]?.lastActivity = uptimeNanoseconds()
        }
    }

    /// Deletes a session and ends its runtime side. Returns `false` for an unknown session.
    @discardableResult
    func delete(_ id: ProxySessionID) -> Bool {
        guard let entry = state.withLockedValue({ $0.entries.removeValue(forKey: id) }) else { return false }
        end(id, entry)
        return true
    }

    /// Deletes sessions that no request or stream has used for `grace`.
    func expire(inactiveFor grace: TimeAmount) {
        let now = uptimeNanoseconds()
        let expired = state.withLockedValue { state -> [(ProxySessionID, Entry)] in
            let expired = state.entries.filter { _, entry in
                entry.leases == 0 && entry.streams == 0 && now >= entry.lastActivity
                    && now - entry.lastActivity >= UInt64(max(0, grace.nanoseconds))
            }
            for id in expired.keys { state.entries.removeValue(forKey: id) }
            return Array(expired)
        }
        for (id, entry) in expired { end(id, entry) }
    }

    func closeAll() {
        let all = state.withLockedValue { state -> [(ProxySessionID, Entry)] in
            defer { state.entries.removeAll() }
            return Array(state.entries)
        }
        for (id, entry) in all { end(id, entry) }
    }

    /// Deletes every session and refuses new ones until `reset` returns, so no session keeps
    /// runtime state that the reset discards.
    func closeAll(during reset: () async -> Void) async {
        state.withLockedValue { state in
            state.resetsInProgress += 1
            state.resetGeneration += 1
        }
        closeAll()
        await reset()
        state.withLockedValue { $0.resetsInProgress -= 1 }
    }

    private func end(_ id: ProxySessionID, _ entry: Entry) {
        delivery.remove(id)
        entry.session.close()
    }
}
