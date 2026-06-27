import Foundation
import XcodeMCPRuntime

extension UpstreamReadinessGate {
    /// The live gate for the stock xcrun mcpbridge upstream: hold
    /// initialization until an Xcode process is available.
    /// Any other upstream invocation gets the always-ready gate.
    package static func liveDefault(
        config: ProxyConfig,
        clock: ClockClient
    ) -> UpstreamReadinessGate {
        guard XcrunArguments.isDefaultMCPBridgeInvocation(config: config) else {
            return .alwaysReady(uptimeNanoseconds: clock.uptimeNanoseconds)
        }

        let processRunner = ProcessRunner()
        return .xcodeMCPBridge(
            uptimeNanoseconds: clock.uptimeNanoseconds,
            sleepNanoseconds: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            runProcess: { request in
                try await processRunner.run(request)
            }
        )
    }

    package static func xcodeMCPBridge(
        uptimeNanoseconds: @escaping @Sendable () -> UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async -> Void,
        runProcess: @escaping @Sendable (ProcessRequest) async throws -> ProcessOutput
    ) -> Self {
        Self(
            isEnabled: true,
            targetName: "mcpbridge",
            pollIntervalNanoseconds: 1_000_000_000,
            progressLogIntervalNanoseconds: 5_000_000_000,
            launchRetryIntervalNanoseconds: 5_000_000_000,
            initialRetryBackoffNanoseconds: 1_000_000_000,
            maxRetryBackoffNanoseconds: 8_000_000_000,
            uptimeNanoseconds: uptimeNanoseconds,
            sleepNanoseconds: sleepNanoseconds,
            isAvailable: {
                let output = try? await runProcess(
                    ProcessRequest(
                        label: "detect-xcode-process",
                        executablePath: "/usr/bin/pgrep",
                        arguments: ["-x", "Xcode"],
                        input: nil
                    )
                )
                guard let output else { return false }
                return XcodeReadinessProbe.processIDs(fromPGrepOutput: output).isEmpty == false
            },
            launchIfUnavailable: {
                let output = try? await runProcess(
                    ProcessRequest(
                        label: "launch-xcode",
                        executablePath: "/usr/bin/open",
                        arguments: ["-a", "Xcode"],
                        input: nil
                    )
                )
                return output?.terminationStatus == 0
            },
            isReady: {
                let output = try? await runProcess(
                    ProcessRequest(
                        label: "detect-xcode-process",
                        executablePath: "/usr/bin/pgrep",
                        arguments: ["-x", "Xcode"],
                        input: nil
                    )
                )
                guard let output else { return false }
                let processIDs = XcodeReadinessProbe.processIDs(fromPGrepOutput: output)
                return XcodeReadinessProbe.isReady(xcodeProcessIDs: processIDs)
            }
        )
    }
}

package enum XcodeReadinessProbe {
    package static func processIDs(fromPGrepOutput output: ProcessOutput) -> Set<pid_t> {
        guard output.terminationStatus == 0 else { return [] }
        return Set(
            output.stdout
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    package static func isReady(xcodeProcessIDs: Set<pid_t>) -> Bool {
        xcodeProcessIDs.isEmpty == false
    }
}
