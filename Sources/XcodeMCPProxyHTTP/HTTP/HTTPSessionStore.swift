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

    private let entries = NIOLockedValueBox<[ProxySessionID: Entry]>([:])
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
        delivery.register(id)
        let session: any ProxyRuntimeSession
        do {
            session = try runtime.openSession(id) { [delivery] data in delivery.deliver(data, to: id) }
        } catch {
            delivery.remove(id)
            throw error
        }
        entries.withLockedValue { $0[id] = Entry(session: session, lastActivity: uptimeNanoseconds()) }
        return session
    }

    func phase(of id: ProxySessionID) -> Phase? {
        entries.withLockedValue { $0[id]?.phase }
    }

    func markInitialized(_ id: ProxySessionID, protocolVersion: String?) {
        entries.withLockedValue { $0[id]?.phase = .initialized(protocolVersion: protocolVersion) }
    }

    /// Lets one request use the session until ``release(_:)``. Returns `nil` for an unknown session,
    /// before the request is processed.
    func acquire(_ id: ProxySessionID) -> (any ProxyRuntimeSession)? {
        entries.withLockedValue { entries in
            guard var entry = entries[id] else { return nil }
            entry.leases += 1
            entry.lastActivity = uptimeNanoseconds()
            entries[id] = entry
            return entry.session
        }
    }

    func release(_ id: ProxySessionID) {
        entries.withLockedValue { entries in
            entries[id]?.leases -= 1
            entries[id]?.lastActivity = uptimeNanoseconds()
        }
    }

    /// Attaches a client's event stream. Returns `false` for an unknown session.
    func openStream(_ id: ProxySessionID, channel: Channel) -> Bool {
        let opened = entries.withLockedValue { entries in
            guard entries[id] != nil else { return false }
            entries[id]?.streams += 1
            entries[id]?.lastActivity = uptimeNanoseconds()
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
        entries.withLockedValue { entries in
            entries[id]?.streams -= 1
            entries[id]?.lastActivity = uptimeNanoseconds()
        }
    }

    /// Deletes a session and ends its runtime side. Returns `false` for an unknown session.
    @discardableResult
    func delete(_ id: ProxySessionID) -> Bool {
        guard let entry = entries.withLockedValue({ $0.removeValue(forKey: id) }) else { return false }
        end(id, entry)
        return true
    }

    /// Deletes sessions that no request or stream has used for `grace`.
    func expire(inactiveFor grace: TimeAmount) {
        let now = uptimeNanoseconds()
        let expired = entries.withLockedValue { entries -> [(ProxySessionID, Entry)] in
            let expired = entries.filter { _, entry in
                entry.leases == 0 && entry.streams == 0 && now >= entry.lastActivity
                    && now - entry.lastActivity >= UInt64(max(0, grace.nanoseconds))
            }
            for id in expired.keys { entries.removeValue(forKey: id) }
            return Array(expired)
        }
        for (id, entry) in expired { end(id, entry) }
    }

    func closeAll() {
        let all = entries.withLockedValue { entries -> [(ProxySessionID, Entry)] in
            defer { entries.removeAll() }
            return Array(entries)
        }
        for (id, entry) in all { end(id, entry) }
    }

    private func end(_ id: ProxySessionID, _ entry: Entry) {
        delivery.remove(id)
        entry.session.close()
    }
}
