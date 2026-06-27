import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPRuntime

package final class ServerRequestTracker: Sendable {
    package struct Route: Sendable {
        package let upstreamIndex: Int
        package let upstreamID: JSONRPC.ID
    }

    private struct StoredRoute: Sendable {
        let route: ServerRequestTracker.Route
        let expiresAt: Date
    }

    private struct State: Sendable {
        var nextClientID: Int64 = 0
        var routesByClientIDKey: [String: StoredRoute] = [:]
        var clientIDKeysInOrder: [String] = []
    }

    private let state = NIOLockedValueBox(State())
    private let routeTimeout: TimeAmount
    private let maxRoutes: Int

    package init(
        routeTimeout: TimeAmount = .seconds(300),
        maxRoutes: Int = 256
    ) {
        self.routeTimeout = routeTimeout
        self.maxRoutes = max(0, maxRoutes)
    }

    package func record(
        upstreamID: JSONRPC.ID,
        upstreamIndex: Int,
        now: Date = Date()
    ) -> JSONRPC.ID {
        state.withLockedValue { state in
            Self.removeExpiredRoutes(now: now, state: &state)
            state.nextClientID += 1
            let clientID = JSONRPC.ID(
                any: "xcode-mcp-proxy.server-request.\(state.nextClientID)"
            )!
            state.routesByClientIDKey[clientID.key] = StoredRoute(
                route: ServerRequestTracker.Route(
                    upstreamIndex: upstreamIndex,
                    upstreamID: upstreamID
                ),
                expiresAt: Self.expirationDate(now: now, timeout: routeTimeout)
            )
            state.clientIDKeysInOrder.append(clientID.key)
            Self.removeOverflowRoutes(maxRoutes: maxRoutes, state: &state)
            return clientID
        }
    }

    package func consume(clientID: JSONRPC.ID, now: Date = Date()) -> ServerRequestTracker.Route? {
        state.withLockedValue { state in
            Self.removeExpiredRoutes(now: now, state: &state)
            guard let stored = state.routesByClientIDKey.removeValue(forKey: clientID.key) else {
                return nil
            }
            state.clientIDKeysInOrder.removeAll { $0 == clientID.key }
            return stored.route
        }
    }

    package func lookup(clientID: JSONRPC.ID, now: Date = Date()) -> ServerRequestTracker.Route? {
        state.withLockedValue { state in
            Self.removeExpiredRoutes(now: now, state: &state)
            return state.routesByClientIDKey[clientID.key]?.route
        }
    }

    @discardableResult
    package func complete(
        clientID: JSONRPC.ID,
        route: ServerRequestTracker.Route,
        now: Date = Date()
    ) -> Bool {
        state.withLockedValue { state in
            Self.removeExpiredRoutes(now: now, state: &state)
            guard let stored = state.routesByClientIDKey[clientID.key],
                stored.route.upstreamIndex == route.upstreamIndex,
                stored.route.upstreamID.key == route.upstreamID.key
            else {
                return false
            }
            state.routesByClientIDKey.removeValue(forKey: clientID.key)
            state.clientIDKeysInOrder.removeAll { $0 == clientID.key }
            return true
        }
    }

    private static func expirationDate(now: Date, timeout: TimeAmount) -> Date {
        let seconds = Double(max(timeout.nanoseconds, 0)) / 1_000_000_000
        return now.addingTimeInterval(seconds)
    }

    private static func removeExpiredRoutes(now: Date, state: inout State) {
        let expiredKeys = state.routesByClientIDKey.compactMap { key, stored in
            stored.expiresAt <= now ? key : nil
        }
        guard expiredKeys.isEmpty == false else { return }
        let expiredKeySet = Set(expiredKeys)
        state.routesByClientIDKey = state.routesByClientIDKey.filter { key, _ in
            expiredKeySet.contains(key) == false
        }
        state.clientIDKeysInOrder.removeAll { expiredKeySet.contains($0) }
    }

    private static func removeOverflowRoutes(maxRoutes: Int, state: inout State) {
        guard maxRoutes > 0 else {
            state.routesByClientIDKey.removeAll()
            state.clientIDKeysInOrder.removeAll()
            return
        }
        while state.clientIDKeysInOrder.count > maxRoutes {
            let removedKey = state.clientIDKeysInOrder.removeFirst()
            state.routesByClientIDKey.removeValue(forKey: removedKey)
        }
    }
}
