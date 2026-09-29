import Foundation
import XcodeMCPCore

extension UpstreamReadinessGate {
    /// Service connections can initialize without a GUI process. Otherwise wait for Xcode.
    static func liveDefault(
        config: ProxyRuntimeConfiguration,
        clock: ClockClient,
        processEventMonitor: any XcodeProcessEventMonitoring
    ) -> UpstreamReadinessGate {
        guard !config.includesXcodeService else {
            return .alwaysReady()
        }

        let processRunner = ProcessRunner()
        return .xcodeMCPBridge(
            sleepNanoseconds: { nanoseconds in
                await clock.sleep(.nanoseconds(Int64(clamping: nanoseconds)))
            },
            launchXcode: {
                let output = try? await processRunner.run(
                    ProcessRequest(
                        label: "launch-xcode",
                        executablePath: "/usr/bin/open",
                        arguments: ["-a", "Xcode"],
                        input: nil
                    )
                )
                return output?.terminationStatus == 0
            },
            snapshot: {
                processEventMonitor.readinessSnapshot()
            },
            waitForChange: { generation in
                await processEventMonitor.waitForReadinessChange(after: generation)
            }
        )
    }

    static func xcodeMCPBridge(
        sleepNanoseconds: @escaping @Sendable (UInt64) async -> Void,
        launchXcode: @escaping @Sendable () async -> Bool,
        snapshot: @escaping @Sendable () async -> UpstreamReadinessSnapshot,
        waitForChange: @escaping @Sendable (_ generation: UInt64) async -> Void
    ) -> Self {
        Self(
            isEnabled: true,
            targetName: "mcpbridge",
            initialRetryBackoffNanoseconds: 1_000_000_000,
            maxRetryBackoffNanoseconds: 8_000_000_000,
            sleepNanoseconds: sleepNanoseconds,
            launchIfUnavailable: launchXcode,
            snapshot: snapshot,
            waitForChange: waitForChange
        )
    }
}
