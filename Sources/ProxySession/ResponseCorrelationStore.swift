import Foundation
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
    static func makeDefaultUpstreams(
        config: ProxyConfig,
        sharedSessionID: String?,
        count: Int
    ) -> [ManagedUpstreamSlot] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XCODE_PID")
        if let sharedSessionID, !sharedSessionID.isEmpty {
            environment["MCP_XCODE_SESSION_ID"] = sharedSessionID
        } else {
            environment.removeValue(forKey: "MCP_XCODE_SESSION_ID")
        }
        let upstreamConfig = UpstreamProcess.Config(
            command: config.upstreamCommand,
            args: config.upstreamArgs,
            environment: environment,
            maxQueuedWriteBytes: {
                let minimum = 1_048_576
                guard config.maxBodyBytes > 0 else { return minimum }
                let multiplied = config.maxBodyBytes.multipliedReportingOverflow(by: 4)
                if multiplied.overflow {
                    return Int.max
                }
                return max(minimum, multiplied.partialValue)
            }()
        )
        if count <= 1 {
            return [ManagedUpstreamSlot(factory: UpstreamProcess(config: upstreamConfig), startImmediately: true)]
        }
        var upstreams: [ManagedUpstreamSlot] = []
        upstreams.reserveCapacity(count)
        for _ in 0..<count {
            upstreams.append(
                ManagedUpstreamSlot(factory: UpstreamProcess(config: upstreamConfig), startImmediately: true)
            )
        }
        return upstreams
    }
}

package final class UpstreamRouter: Sendable {
    private struct RequestLookupKey: Hashable, Sendable {
        let sessionID: String
        let requestIDKey: String
    }

    private struct State: Sendable {
        var nextID: Int64 = 1
        var mappingsByUpstream: [[Int64: UpstreamMapping]] = []
        var upstreamIDByRequestKeyByUpstream: [[RequestLookupKey: Int64]] = []
        var recentlyReleasedResponseIDsByUpstream: [[Int64]] = []
    }

    private let state = NIOLockedValueBox(State())
    private let lateResponseMarkerLimit = 512

    init(upstreamCount: Int) {
        state.withLockedValue { state in
            state.mappingsByUpstream = Array(repeating: [:], count: upstreamCount)
            state.upstreamIDByRequestKeyByUpstream = Array(repeating: [:], count: upstreamCount)
            state.recentlyReleasedResponseIDsByUpstream = Array(repeating: [], count: upstreamCount)
        }
    }

    func assign(upstreamIndex: Int, sessionID: String, originalID: RPCID, isInitialize: Bool)
        -> Int64
    {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionID: sessionID,
                originalID: originalID,
                isInitialize: isInitialize
            )
            if isInitialize == false {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex][requestKey] = id
            }
            return id
        }
    }

    func assignInitialize(upstreamIndex: Int) -> Int64 {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamMapping(
                sessionID: nil,
                originalID: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(upstreamIndex: Int, upstreamID: Int64) -> UpstreamMapping? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            if let mapping,
                let sessionID = mapping.sessionID,
                let originalID = mapping.originalID
            {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeAll { $0 == upstreamID }
            return mapping
        }
    }

    func remove(upstreamIndex: Int, upstreamID: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            if let mapping,
                let sessionID = mapping.sessionID,
                let originalID = mapping.originalID
            {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
            if mapping?.isInitialize == false {
                Self.recordReleasedResponseID(
                    upstreamID,
                    upstreamIndex: upstreamIndex,
                    state: &state,
                    limit: lateResponseMarkerLimit
                )
            }
        }
    }

    func remove(
        upstreamIndex: Int,
        sessionID: String,
        requestIDKey: String
    ) -> Int64? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let requestKey = Self.requestLookupKey(sessionID: sessionID, requestIDKey: requestIDKey)
            guard
                let upstreamID = state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            else {
                return nil
            }
            state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            Self.recordReleasedResponseID(
                upstreamID,
                upstreamIndex: upstreamIndex,
                state: &state,
                limit: lateResponseMarkerLimit
            )
            return upstreamID
        }
    }

    func reset(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            state.mappingsByUpstream[upstreamIndex].removeAll()
            state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeAll()
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeAll()
        }
    }

    func resetAll() {
        state.withLockedValue { state in
            for upstreamIndex in state.mappingsByUpstream.indices {
                state.mappingsByUpstream[upstreamIndex].removeAll()
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeAll()
                state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeAll()
            }
        }
    }

    func consumeReleasedResponseMarker(upstreamIndex: Int, upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.recentlyReleasedResponseIDsByUpstream.count else {
                return false
            }
            guard let index = state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].firstIndex(of: upstreamID)
            else {
                return false
            }
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].remove(at: index)
            return true
        }
    }

    private static func requestLookupKey(sessionID: String, requestIDKey: String)
        -> RequestLookupKey
    {
        RequestLookupKey(sessionID: sessionID, requestIDKey: requestIDKey)
    }

    private static func recordReleasedResponseID(
        _ upstreamID: Int64,
        upstreamIndex: Int,
        state: inout State,
        limit: Int
    ) {
        guard upstreamIndex >= 0, upstreamIndex < state.recentlyReleasedResponseIDsByUpstream.count else {
            return
        }
        state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].append(upstreamID)
        if state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].count > limit {
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeFirst(
                state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].count - limit
            )
        }
    }
}

package struct UpstreamMapping: Sendable {
    package let sessionID: String?
    package let originalID: RPCID?
    package let isInitialize: Bool
}
