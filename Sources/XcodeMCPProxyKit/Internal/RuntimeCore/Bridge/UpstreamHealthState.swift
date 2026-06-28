import XcodeMCPKit
import Foundation

extension Upstream {
    enum HealthState: Sendable {
        case healthy
        case degraded
        case quarantined(untilUptimeNs: UInt64)
    }
}
