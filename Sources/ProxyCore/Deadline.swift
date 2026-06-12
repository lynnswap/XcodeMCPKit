import NIO

/// A monotonic (uptime-based) point in time bounding one request.
/// Create it once at the entry point with `fromNow` and pass it down by
/// value; `Deadline?` being nil means "no deadline".
package struct Deadline: Sendable {
    package let uptimeNanoseconds: UInt64
    private let clock: ClockClient

    package init(uptimeNanoseconds: UInt64, clock: ClockClient = .liveValue) {
        self.uptimeNanoseconds = uptimeNanoseconds
        self.clock = clock
    }

    /// Returns nil when `timeout` is nil or non-positive (no deadline).
    package static func fromNow(
        _ timeout: TimeAmount?,
        clock: ClockClient = .liveValue
    ) -> Deadline? {
        guard let timeout, timeout.nanoseconds > 0 else {
            return nil
        }
        let now = clock.uptimeNanoseconds()
        let clamped = min(UInt64(timeout.nanoseconds), UInt64.max &- now)
        return Deadline(uptimeNanoseconds: now &+ clamped, clock: clock)
    }

    package var hasExpired: Bool {
        clock.uptimeNanoseconds() >= uptimeNanoseconds
    }

    /// Remaining time until the deadline; `.nanoseconds(0)` once expired.
    package func remaining() -> TimeAmount {
        let now = clock.uptimeNanoseconds()
        guard uptimeNanoseconds > now else {
            return .nanoseconds(0)
        }
        return .nanoseconds(Int64(min(uptimeNanoseconds - now, UInt64(Int64.max))))
    }
}
