import XcodeMCPKit
import NIOConcurrencyHelpers

final class UpstreamRouter: Sendable {
    private struct RequestLookupKey: Hashable, Sendable {
        let sessionID: String
        let requestIDKey: String
    }

    private struct State: Sendable {
        var nextID: Int64 = 1
        var mappingsByUpstream: [[Int64: UpstreamRouter.Mapping]] = []
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

    func assign(upstreamIndex: Int, sessionID: String, originalID: JSONRPC.ID, isInitialize: Bool)
        -> Int64
    {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamRouter.Mapping(
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
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamRouter.Mapping(
                sessionID: nil,
                originalID: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(upstreamIndex: Int, upstreamID: Int64) -> UpstreamRouter.Mapping? {
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
    struct Mapping: Sendable {
        let sessionID: String?
        let originalID: JSONRPC.ID?
        let isInitialize: Bool
    }
}
