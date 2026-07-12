import Foundation

package struct UpstreamReadinessSnapshot: Sendable {
    package let isReady: Bool
    package let generation: UInt64

    package init(isReady: Bool, generation: UInt64) {
        self.isReady = isReady
        self.generation = generation
    }
}

package struct UpstreamReadinessGate: Sendable {
    package let isEnabled: Bool
    package let targetName: String
    package let initialRetryBackoffNanoseconds: UInt64
    package let maxRetryBackoffNanoseconds: UInt64
    package let sleepNanoseconds: @Sendable (UInt64) async -> Void
    package let launchIfUnavailable: (@Sendable () async -> Bool)?
    package let snapshot: @Sendable () async -> UpstreamReadinessSnapshot
    package let waitForChange: @Sendable (_ generation: UInt64) async -> Void

    package init(
        isEnabled: Bool,
        targetName: String,
        initialRetryBackoffNanoseconds: UInt64,
        maxRetryBackoffNanoseconds: UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async -> Void,
        launchIfUnavailable: (@Sendable () async -> Bool)? = nil,
        snapshot: @escaping @Sendable () async -> UpstreamReadinessSnapshot,
        waitForChange: @escaping @Sendable (_ generation: UInt64) async -> Void
    ) {
        self.isEnabled = isEnabled
        self.targetName = targetName
        self.initialRetryBackoffNanoseconds = initialRetryBackoffNanoseconds
        self.maxRetryBackoffNanoseconds = maxRetryBackoffNanoseconds
        self.sleepNanoseconds = sleepNanoseconds
        self.launchIfUnavailable = launchIfUnavailable
        self.snapshot = snapshot
        self.waitForChange = waitForChange
    }

    package static func alwaysReady() -> Self {
        Self(
            isEnabled: false,
            targetName: "upstream",
            initialRetryBackoffNanoseconds: 0,
            maxRetryBackoffNanoseconds: 0,
            sleepNanoseconds: { _ in },
            launchIfUnavailable: nil,
            snapshot: {
                UpstreamReadinessSnapshot(isReady: true, generation: 0)
            },
            waitForChange: { _ in }
        )
    }
}
