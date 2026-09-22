import Foundation

package struct ClockClient: Sendable {
    package var now: @Sendable () -> Date
    package var uptimeNanoseconds: @Sendable () -> UInt64
    package var sleep: @Sendable (Duration) async -> Void
    package var sleepForTimeInterval: @Sendable (TimeInterval) -> Void

    package init(
        now: @escaping @Sendable () -> Date,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64,
        sleep: @escaping @Sendable (Duration) async -> Void,
        sleepForTimeInterval: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.now = now
        self.uptimeNanoseconds = uptimeNanoseconds
        self.sleep = sleep
        self.sleepForTimeInterval = sleepForTimeInterval
    }

    package static let liveValue = Self(
        now: { Date() },
        uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds },
        sleep: { duration in
            try? await Task.sleep(for: duration)
        },
        sleepForTimeInterval: { interval in
            Thread.sleep(forTimeInterval: interval)
        }
    )

    package static let testValue = Self(
        now: { Date(timeIntervalSince1970: 0) },
        uptimeNanoseconds: { 0 },
        sleep: { _ in },
        sleepForTimeInterval: { _ in }
    )
}
