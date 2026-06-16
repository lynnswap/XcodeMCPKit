import NIOConcurrencyHelpers
import ProxyMCP

package struct ServerRequestRoute: Sendable {
    package let upstreamIndex: Int
    package let upstreamID: RPCID
}

package final class ServerRequestTracker: Sendable {
    private struct State: Sendable {
        var nextClientID: Int64 = 0
        var routesByClientIDKey: [String: ServerRequestRoute] = [:]
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func record(upstreamID: RPCID, upstreamIndex: Int) -> RPCID {
        state.withLockedValue { state in
            state.nextClientID += 1
            let clientID = RPCID(
                any: "xcode-mcp-proxy.server-request.\(state.nextClientID)"
            )!
            state.routesByClientIDKey[clientID.key] = ServerRequestRoute(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            )
            return clientID
        }
    }

    package func consume(clientID: RPCID) -> ServerRequestRoute? {
        state.withLockedValue { state in
            state.routesByClientIDKey.removeValue(forKey: clientID.key)
        }
    }
}
