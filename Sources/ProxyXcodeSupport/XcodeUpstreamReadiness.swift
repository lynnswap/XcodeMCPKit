import ApplicationServices
import Foundation
import ProxyCore

extension UpstreamReadinessGate {
    /// The live gate for the stock xcrun mcpbridge upstream: hold
    /// initialization until a running Xcode shows a ready workspace window.
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
                return XcodeReadinessProbe.isReady(
                    xcodeProcessIDs: processIDs,
                    windows: XcodeReadinessProbe.visibleWindowSnapshots(
                        xcodeProcessIDs: processIDs
                    )
                )
            }
        )
    }
}

package enum XcodeReadinessProbe {
    package struct WindowSnapshot: Equatable, Sendable {
        package let ownerPID: pid_t
        package let title: String
        package let layer: Int
        package let alpha: Double

        package init(ownerPID: pid_t, title: String, layer: Int, alpha: Double) {
            self.ownerPID = ownerPID
            self.title = title
            self.layer = layer
            self.alpha = alpha
        }
    }

    package static func processIDs(fromPGrepOutput output: ProcessOutput) -> Set<pid_t> {
        guard output.terminationStatus == 0 else { return [] }
        return Set(
            output.stdout
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    package static func hasReadyWorkspaceWindow(
        xcodeProcessIDs: Set<pid_t>,
        windows: [WindowSnapshot]
    ) -> Bool {
        guard xcodeProcessIDs.isEmpty == false else { return false }
        return windows.contains { window in
            xcodeProcessIDs.contains(window.ownerPID)
                && window.layer == 0
                && window.alpha > 0
                && isReadyWorkspaceTitle(window.title)
        }
    }

    package static func isReady(
        xcodeProcessIDs: Set<pid_t>,
        windows: [WindowSnapshot]?
    ) -> Bool {
        guard xcodeProcessIDs.isEmpty == false else { return false }
        guard let windows else {
            return true
        }
        return hasReadyWorkspaceWindow(xcodeProcessIDs: xcodeProcessIDs, windows: windows)
    }

    package static func visibleWindowSnapshots(xcodeProcessIDs: Set<pid_t>) -> [WindowSnapshot]? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        return accessibilityWindowSnapshots(xcodeProcessIDs: xcodeProcessIDs)
    }

    private static func accessibilityWindowSnapshots(
        xcodeProcessIDs: Set<pid_t>
    ) -> [WindowSnapshot] {
        xcodeProcessIDs.flatMap { processID -> [WindowSnapshot] in
            let app = AXUIElementCreateApplication(processID)
            var rawWindows: CFTypeRef?
            let error = unsafe AXUIElementCopyAttributeValue(
                app,
                kAXWindowsAttribute as CFString,
                &rawWindows
            )
            guard error == .success, let windows = rawWindows as? [AXUIElement] else {
                return []
            }
            return windows.map { window in
                let minimized = accessibilityBoolAttribute(
                    window,
                    attribute: kAXMinimizedAttribute
                ) ?? false
                return WindowSnapshot(
                    ownerPID: processID,
                    title: accessibilityStringAttribute(window, attribute: kAXTitleAttribute) ?? "",
                    layer: 0,
                    alpha: minimized ? 0 : 1
                )
            }
        }
    }

    private static func isReadyWorkspaceTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard trimmed.localizedCaseInsensitiveCompare("Welcome to Xcode") != .orderedSame else {
            return false
        }
        return true
    }

    private static func accessibilityStringAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var value: CFTypeRef?
        let error = unsafe AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private static func accessibilityBoolAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> Bool? {
        var value: CFTypeRef?
        let error = unsafe AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? Bool
    }
}
