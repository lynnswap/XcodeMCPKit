import Foundation

/// How long one operation may take, including session recovery, a replay,
/// and every page of a paginated request.
public enum XcodeMCPTimeout: Equatable, Sendable {
    /// ``XcodeMCPConfiguration/requestTimeout``.
    case `default`

    /// No client-side limit.
    case unlimited

    /// A limit for this operation. The duration must be greater than zero.
    case after(Duration)
}

/// State of the client connection.
///
/// `generation` increases when a fresh transport connection becomes current.
/// Identifiers that a server issued for an earlier generation may no longer be
/// valid.
public struct XcodeMCPConnectionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case initializing
        case ready
        case recovering

        /// Requests fail until ``XcodeMCP/reconnect(timeout:)`` succeeds. The
        /// error is ``XcodeMCPError/transportUnavailable(_:)``,
        /// ``XcodeMCPError/sessionRecoveryFailed(_:)``, or
        /// ``XcodeMCPError/invalidResponse(_:)``.
        case unavailable(XcodeMCPError)

        /// ``XcodeMCP/close()`` was called.
        case closed
    }

    public let generation: UInt64
    public let phase: Phase

    package init(generation: UInt64, phase: Phase) {
        self.generation = generation
        self.phase = phase
    }
}
