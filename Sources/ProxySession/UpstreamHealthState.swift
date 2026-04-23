import Foundation

package enum UpstreamHealthState: Sendable {
    case healthy
    case degraded
    case quarantined(untilUptimeNs: UInt64)
}
