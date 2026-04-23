import Foundation
import NIOConcurrencyHelpers
import ProxyMCP

package struct CanonicalBrokerIncompatibility: Codable, Sendable {
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

package struct CanonicalBrokerSnapshot: Sendable {
    package let initializeResult: JSONValue?
    package let initializeSourceUpstream: Int?
    package let toolsCatalogRaw: JSONValue?
    package let toolsSourceUpstream: Int?
    package let lastIncompatibility: CanonicalBrokerIncompatibility?

    package init(
        initializeResult: JSONValue?,
        initializeSourceUpstream: Int?,
        toolsCatalogRaw: JSONValue?,
        toolsSourceUpstream: Int?,
        lastIncompatibility: CanonicalBrokerIncompatibility?
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

package final class CanonicalBrokerState: Sendable {
    private struct State: Sendable {
        var initializeResult: JSONValue?
        var initializeSourceUpstream: Int?
        var toolsCatalogRaw: JSONValue?
        var toolsSourceUpstream: Int?
        var lastIncompatibility: CanonicalBrokerIncompatibility?
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func snapshot() -> CanonicalBrokerSnapshot {
        state.withLockedValue { state in
            CanonicalBrokerSnapshot(
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
        sourceUpstream: Int
    ) {
        state.withLockedValue { state in
            state.toolsCatalogRaw = rawResult
            state.toolsSourceUpstream = sourceUpstream
        }
    }

    package func clearInitialize() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
        }
    }

    package func clearToolsCatalog() {
        state.withLockedValue { state in
            state.toolsCatalogRaw = nil
            state.toolsSourceUpstream = nil
        }
    }

    package func reset() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.toolsCatalogRaw = nil
            state.toolsSourceUpstream = nil
            state.lastIncompatibility = nil
        }
    }

    package func recordIncompatibility(
        upstreamIndex: Int,
        kind: String,
        reason: String
    ) {
        state.withLockedValue { state in
            state.lastIncompatibility = CanonicalBrokerIncompatibility(
                upstreamIndex: upstreamIndex,
                kind: kind,
                reason: reason
            )
        }
    }
}
