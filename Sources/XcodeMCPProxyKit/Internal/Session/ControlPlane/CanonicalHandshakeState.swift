import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class CanonicalHandshakeState: Sendable {
    struct Incompatibility: Codable, Sendable {
        let upstreamIndex: Int
        let kind: String
        let reason: String
        let observedAt: Date

        init(
            upstreamIndex: Int,
            kind: String,
            reason: String,
            observedAt: Date = Date()
        ) {
            self.upstreamIndex = upstreamIndex
            self.kind = kind
            self.reason = reason
            self.observedAt = observedAt
        }
    }

    struct Snapshot: Sendable {
        let initializeResult: JSONValue?
        let initializeSourceUpstream: Int?
        let lastIncompatibility: Incompatibility?
        let initializeEpoch: UInt64

        var isInitialized: Bool { initializeResult != nil }
    }

    private struct State: Sendable {
        var initializeResult: JSONValue?
        var initializeSourceUpstream: Int?
        var lastIncompatibility: Incompatibility?
        var initializeEpoch: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())

    func snapshot() -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                initializeResult: state.initializeResult,
                initializeSourceUpstream: state.initializeSourceUpstream,
                lastIncompatibility: state.lastIncompatibility,
                initializeEpoch: state.initializeEpoch
            )
        }
    }

    func initializeResult() -> JSONValue? {
        state.withLockedValue(\.initializeResult)
    }

    func initializeSourceUpstream() -> Int? {
        state.withLockedValue(\.initializeSourceUpstream)
    }

    func syncCanonicalInitialize(_ result: JSONValue, sourceUpstream: Int) {
        state.withLockedValue { state in
            state.initializeResult = result
            state.initializeSourceUpstream = sourceUpstream
        }
    }

    func clearInitialize() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.initializeEpoch &+= 1
        }
    }

    func reset() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.lastIncompatibility = nil
            state.initializeEpoch &+= 1
        }
    }

    func recordIncompatibility(
        upstreamIndex: Int,
        kind: String,
        reason: String
    ) {
        state.withLockedValue { state in
            state.lastIncompatibility = Incompatibility(
                upstreamIndex: upstreamIndex,
                kind: kind,
                reason: reason
            )
        }
    }
}
