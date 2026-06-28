import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class CanonicalBrokerState: Sendable {
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
        let toolsCatalogRaw: JSONValue?
        let toolsSourceUpstream: Int?
        let lastIncompatibility: CanonicalBrokerState.Incompatibility?

        init(
            initializeResult: JSONValue?,
            initializeSourceUpstream: Int?,
            toolsCatalogRaw: JSONValue?,
            toolsSourceUpstream: Int?,
            lastIncompatibility: CanonicalBrokerState.Incompatibility?
        ) {
            self.initializeResult = initializeResult
            self.initializeSourceUpstream = initializeSourceUpstream
            self.toolsCatalogRaw = toolsCatalogRaw
            self.toolsSourceUpstream = toolsSourceUpstream
            self.lastIncompatibility = lastIncompatibility
        }

        var canonicalReady: Bool {
            initializeResult != nil && toolsCatalogRaw != nil
        }
    }

    private struct State: Sendable {
        var initializeResult: JSONValue?
        var initializeSourceUpstream: Int?
        var toolsCatalogRaw: JSONValue?
        var toolsSourceUpstream: Int?
        var lastIncompatibility: CanonicalBrokerState.Incompatibility?
        /// Bumped on every clear/reset. Asynchronous load completions
        /// captured under an older generation must not write back, which
        /// is what allows invalidation to clear synchronously without
        /// waiting for in-flight loads to be cancelled.
        var generation: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())

    init() {}

    func snapshot() -> CanonicalBrokerState.Snapshot {
        state.withLockedValue { state in
            CanonicalBrokerState.Snapshot(
                initializeResult: state.initializeResult,
                initializeSourceUpstream: state.initializeSourceUpstream,
                toolsCatalogRaw: state.toolsCatalogRaw,
                toolsSourceUpstream: state.toolsSourceUpstream,
                lastIncompatibility: state.lastIncompatibility
            )
        }
    }

    func initializeResult() -> JSONValue? {
        state.withLockedValue { $0.initializeResult }
    }

    func initializeSourceUpstream() -> Int? {
        state.withLockedValue { $0.initializeSourceUpstream }
    }

    func toolsCatalogRaw() -> JSONValue? {
        state.withLockedValue { $0.toolsCatalogRaw }
    }

    func toolsSourceUpstream() -> Int? {
        state.withLockedValue { $0.toolsSourceUpstream }
    }

    func generation() -> UInt64 {
        state.withLockedValue { $0.generation }
    }

    func syncCanonicalInitialize(
        _ result: JSONValue,
        sourceUpstream: Int
    ) {
        state.withLockedValue { state in
            state.initializeResult = result
            state.initializeSourceUpstream = sourceUpstream
        }
    }

    func syncCanonicalToolsCatalog(
        _ rawResult: JSONValue,
        sourceUpstream: Int,
        onlyIfGeneration expectedGeneration: UInt64? = nil
    ) {
        state.withLockedValue { state in
            if let expectedGeneration, state.generation != expectedGeneration {
                return
            }
            state.toolsCatalogRaw = rawResult
            state.toolsSourceUpstream = sourceUpstream
        }
    }

    func clearInitialize() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.generation += 1
        }
    }

    func clearToolsCatalog() {
        state.withLockedValue { state in
            state.toolsCatalogRaw = nil
            state.toolsSourceUpstream = nil
            state.generation += 1
        }
    }

    func reset() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.toolsCatalogRaw = nil
            state.toolsSourceUpstream = nil
            state.lastIncompatibility = nil
            state.generation += 1
        }
    }

    func recordIncompatibility(
        upstreamIndex: Int,
        kind: String,
        reason: String
    ) {
        state.withLockedValue { state in
            state.lastIncompatibility = CanonicalBrokerState.Incompatibility(
                upstreamIndex: upstreamIndex,
                kind: kind,
                reason: reason
            )
        }
    }
}
