import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class CanonicalHandshakeState: Sendable {
    struct InitializePublicationLease: Sendable, Hashable {
        fileprivate let publicationID: UInt64
        fileprivate let sourceUpstream: Int
        fileprivate let initializeEpoch: UInt64

        var sourceUpstreamIndex: Int { sourceUpstream }
    }

    struct InitializeJoinLease: Sendable {
        fileprivate let initializeEpoch: UInt64
        fileprivate let result: JSONValue
    }

    struct InitializePublication: Sendable, Hashable {
        fileprivate let lease: InitializePublicationLease
    }

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
        var nextPublicationID: UInt64 = 0
        var reservedPublicationID: UInt64?
        var reservedPublicationSource: Int?
        var currentPublicationID: UInt64?
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
            state.reservedPublicationID = nil
            state.reservedPublicationSource = nil
            state.currentPublicationID = nil
            state.initializeEpoch &+= 1
        }
    }

    func prepareInitializePublication(
        sourceUpstream: Int
    ) -> InitializePublicationLease? {
        state.withLockedValue { state in
            guard state.initializeResult == nil,
                  state.reservedPublicationID == nil else { return nil }
            state.nextPublicationID &+= 1
            let lease = InitializePublicationLease(
                publicationID: state.nextPublicationID,
                sourceUpstream: sourceUpstream,
                initializeEpoch: state.initializeEpoch
            )
            state.reservedPublicationID = lease.publicationID
            state.reservedPublicationSource = sourceUpstream
            return lease
        }
    }

    func publishCanonicalInitialize(
        _ result: JSONValue,
        lease: InitializePublicationLease
    ) -> InitializePublication? {
        state.withLockedValue { state in
            guard state.initializeEpoch == lease.initializeEpoch,
                  state.initializeResult == nil,
                  state.reservedPublicationID == lease.publicationID else { return nil }
            state.initializeResult = result
            state.initializeSourceUpstream = lease.sourceUpstream
            state.currentPublicationID = lease.publicationID
            state.reservedPublicationID = nil
            state.reservedPublicationSource = nil
            state.initializeEpoch &+= 1
            return InitializePublication(lease: lease)
        }
    }

    func prepareInitializeJoin(
        expectedResult: JSONValue
    ) -> InitializeJoinLease? {
        state.withLockedValue { state in
            guard state.initializeResult == expectedResult else { return nil }
            return InitializeJoinLease(
                initializeEpoch: state.initializeEpoch,
                result: expectedResult
            )
        }
    }

    func validateInitializeJoin(_ lease: InitializeJoinLease) -> Bool {
        state.withLockedValue { state in
            state.initializeEpoch == lease.initializeEpoch
                && state.initializeResult == lease.result
        }
    }

    func invalidateInitializePublication(sourceUpstream: Int) {
        state.withLockedValue { state in
            if state.reservedPublicationSource == sourceUpstream {
                state.reservedPublicationID = nil
                state.reservedPublicationSource = nil
            }
            if state.initializeSourceUpstream == sourceUpstream,
               state.currentPublicationID != nil {
                state.initializeResult = nil
                state.initializeSourceUpstream = nil
                state.currentPublicationID = nil
                state.initializeEpoch &+= 1
            }
        }
    }

    func cancelInitializePublication(_ lease: InitializePublicationLease) {
        state.withLockedValue { state in
            if state.reservedPublicationID == lease.publicationID {
                state.reservedPublicationID = nil
                state.reservedPublicationSource = nil
            }
            guard state.currentPublicationID == lease.publicationID,
                  state.initializeSourceUpstream == lease.sourceUpstream else { return }
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.currentPublicationID = nil
            state.initializeEpoch &+= 1
        }
    }

    func clearInitialize() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.reservedPublicationID = nil
            state.reservedPublicationSource = nil
            state.currentPublicationID = nil
            state.initializeEpoch &+= 1
        }
    }

    func reset() {
        state.withLockedValue { state in
            state.initializeResult = nil
            state.initializeSourceUpstream = nil
            state.lastIncompatibility = nil
            state.reservedPublicationID = nil
            state.reservedPublicationSource = nil
            state.currentPublicationID = nil
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
