import Foundation

package struct UpstreamReadinessGate: Sendable {
    package let isEnabled: Bool
    package let targetName: String
    package let pollIntervalNanoseconds: UInt64
    package let progressLogIntervalNanoseconds: UInt64
    package let launchRetryIntervalNanoseconds: UInt64
    package let initialRetryBackoffNanoseconds: UInt64
    package let maxRetryBackoffNanoseconds: UInt64
    package let uptimeNanoseconds: @Sendable () -> UInt64
    package let sleepNanoseconds: @Sendable (UInt64) async -> Void
    package let isAvailable: (@Sendable () async -> Bool)?
    package let launchIfUnavailable: (@Sendable () async -> Bool)?
    package let isReady: @Sendable () async -> Bool

    package init(
        isEnabled: Bool,
        targetName: String,
        pollIntervalNanoseconds: UInt64,
        progressLogIntervalNanoseconds: UInt64,
        launchRetryIntervalNanoseconds: UInt64,
        initialRetryBackoffNanoseconds: UInt64,
        maxRetryBackoffNanoseconds: UInt64,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async -> Void,
        isAvailable: (@Sendable () async -> Bool)? = nil,
        launchIfUnavailable: (@Sendable () async -> Bool)? = nil,
        isReady: @escaping @Sendable () async -> Bool
    ) {
        self.isEnabled = isEnabled
        self.targetName = targetName
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.progressLogIntervalNanoseconds = progressLogIntervalNanoseconds
        self.launchRetryIntervalNanoseconds = launchRetryIntervalNanoseconds
        self.initialRetryBackoffNanoseconds = initialRetryBackoffNanoseconds
        self.maxRetryBackoffNanoseconds = maxRetryBackoffNanoseconds
        self.uptimeNanoseconds = uptimeNanoseconds
        self.sleepNanoseconds = sleepNanoseconds
        self.isAvailable = isAvailable
        self.launchIfUnavailable = launchIfUnavailable
        self.isReady = isReady
    }

    package static func alwaysReady(
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) -> Self {
        Self(
            isEnabled: false,
            targetName: "upstream",
            pollIntervalNanoseconds: 0,
            progressLogIntervalNanoseconds: 0,
            launchRetryIntervalNanoseconds: 0,
            initialRetryBackoffNanoseconds: 0,
            maxRetryBackoffNanoseconds: 0,
            uptimeNanoseconds: uptimeNanoseconds,
            sleepNanoseconds: { _ in },
            isAvailable: { true },
            launchIfUnavailable: nil,
            isReady: { true }
        )
    }
}
