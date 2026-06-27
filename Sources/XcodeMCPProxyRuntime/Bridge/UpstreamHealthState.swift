import XcodeMCPCore
import XcodeMCPProcessRuntime
import Foundation

extension Upstream {
    package enum HealthState: Sendable {
        case healthy
        case degraded
        case quarantined(untilUptimeNs: UInt64)
    }
}
