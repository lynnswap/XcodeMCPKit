import XcodeMCPCore

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

    /// Creates one absolute deadline for a complete logical operation.
    package static func fromNow(
        _ timeout: Duration?,
        clock: ClockClient = .liveValue
    ) -> Deadline? {
        guard let timeout else { return nil }
        let components = timeout.components
        precondition(
            components.seconds > 0 || components.attoseconds > 0,
            "Deadline duration must be greater than zero; nil is the only disabled value"
        )
        let seconds = UInt64(max(0, components.seconds))
        let nanoseconds = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let secondsResult = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let durationNanoseconds: UInt64
        if secondsResult.overflow {
            durationNanoseconds = .max
        } else {
            let total = secondsResult.partialValue.addingReportingOverflow(nanoseconds)
            durationNanoseconds = total.overflow ? .max : total.partialValue
        }
        let now = clock.uptimeNanoseconds()
        return Deadline(
            uptimeNanoseconds: now &+ min(durationNanoseconds, UInt64.max &- now),
            clock: clock
        )
    }

    package var hasExpired: Bool {
        clock.uptimeNanoseconds() >= uptimeNanoseconds
    }

    /// Remaining time until the deadline; zero once expired.
    package func remainingDuration() -> Duration {
        let now = clock.uptimeNanoseconds()
        guard uptimeNanoseconds > now else { return .zero }
        return .nanoseconds(Int64(min(uptimeNanoseconds - now, UInt64(Int64.max))))
    }
}
