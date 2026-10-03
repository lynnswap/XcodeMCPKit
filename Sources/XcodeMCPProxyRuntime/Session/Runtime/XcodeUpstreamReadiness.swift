import Foundation
import XcodeMCPCore

extension UpstreamReadinessGate {
    static func liveDefault(
        config: ProxyRuntimeConfiguration,
        clock: ClockClient,
        processEventMonitor: any XcodeProcessEventMonitoring
    ) -> UpstreamReadinessGate {
        .alwaysReady()
    }
}
