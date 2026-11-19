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

/// A connection failure that changes the action available to the consumer.
public enum XcodeMCPConnectionFailure: Equatable, Sendable {
    case transportUnavailable(String)
    case sessionRecoveryFailed(String)
    case protocolViolation(String)
}

public enum XcodeMCPCloseReason: Equatable, Sendable {
    case requested
}

/// Atomic state of the client connection.
///
/// `sequence` increases for every published state. `generation` increases only
/// when a fresh transport connection becomes current.
public struct XcodeMCPConnectionSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case initializing
        case ready
        case recovering
        case unavailable(XcodeMCPConnectionFailure)
        case closed(XcodeMCPCloseReason)
    }

    public let sequence: UInt64
    public let generation: UInt64
    public let phase: Phase

    package init(sequence: UInt64, generation: UInt64, phase: Phase) {
        self.sequence = sequence
        self.generation = generation
        self.phase = phase
    }
}
