import Foundation

/// Per-operation timeout and replay policy.
public struct XcodeMCPRequestOptions: Equatable, Sendable {
    public enum Timeout: Equatable, Sendable {
        case configurationDefault
        case disabled
        case after(Duration)
    }

    public enum ReplayPolicy: Equatable, Sendable {
        case never
        case onceWhenRejectedBeforeProcessing
    }

    public var timeout: Timeout
    public var replayPolicy: ReplayPolicy

    public init(
        timeout: Timeout = .configurationDefault,
        replayPolicy: ReplayPolicy = .onceWhenRejectedBeforeProcessing
    ) {
        self.timeout = timeout
        self.replayPolicy = replayPolicy
    }
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
