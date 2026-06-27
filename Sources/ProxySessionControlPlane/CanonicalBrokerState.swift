import Foundation
import NIOConcurrencyHelpers
import XcodeMCPRuntime

package final class CanonicalBrokerState: Sendable {
    package struct Incompatibility: Codable, Sendable {
        package let upstreamIndex: Int
        package let kind: String
        package let reason: String
        package let observedAt: Date

        package init(
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

    package struct Snapshot: Sendable {
        package let initializeResult: JSONValue?
        package let initializeSourceUpstream: Int?
        package let toolsCatalogRaw: JSONValue?
        package let toolsSourceUpstream: Int?
        package let lastIncompatibility: CanonicalBrokerState.Incompatibility?

        package init(
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

        package var canonicalReady: Bool {
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

    package init() {}

    package func snapshot() -> CanonicalBrokerState.Snapshot {
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

    package func initializeResult() -> JSONValue? {
        state.withLockedValue { $0.initializeResult }
    }

    package func initializeSourceUpstream() -> Int? {
        state.withLockedValue { $0.initializeSourceUpstream }
    }

    package func toolsCatalogRaw() -> JSONValue? {
        state.withLockedValue { $0.toolsCatalogRaw }
    }

    package func toolsSourceUpstream() -> Int? {
        state.withLockedValue { $0.toolsSourceUpstream }
    }

    package func generation() -> UInt64 {
        state.withLockedValue { $0.generation }
    }

    package func syncCanonicalInitialize(
        _ result: JSONValue,
        sourceUpstream: Int
    ) {
        state.withLockedValue { state in
            state.initializeResult = result
            state.initializeSourceUpstream = sourceUpstream
        }
    }

    package func syncCanonicalToolsCatalog(
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

    package func clearInitialize() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.generation += 1
        }
    }

    package func clearToolsCatalog() {
        state.withLockedValue { state in
            state.toolsCatalogRaw = nil
            state.toolsSourceUpstream = nil
            state.generation += 1
        }
    }

    package func reset() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.toolsCatalogRaw = nil
            state.toolsSourceUpstream = nil
            state.lastIncompatibility = nil
            state.generation += 1
        }
    }

    package func recordIncompatibility(
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
