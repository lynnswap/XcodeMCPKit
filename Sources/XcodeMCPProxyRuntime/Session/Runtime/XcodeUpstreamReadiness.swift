import Foundation
import XcodeMCPCore

extension UpstreamReadinessGate {
    static func liveDefault(clock: ClockClient) -> UpstreamReadinessGate {
        Self(
            isEnabled: true,
            targetName: "native host",
            initialRetryBackoffNanoseconds: 1_000_000_000,
            maxRetryBackoffNanoseconds: 8_000_000_000,
            sleepNanoseconds: { nanoseconds in
                await clock.sleep(.nanoseconds(Int64(clamping: nanoseconds)))
            },
            snapshot: { UpstreamReadinessSnapshot(isReady: true, generation: 0) },
            waitForChange: { _ in }
        )
    }
}
