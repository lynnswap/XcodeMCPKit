import XcodeMCPCore
import Foundation
import XcodeMCPKit

struct ExistingProxyServerProcessController: DependencyClient {
    var terminateExistingServer:
        @Sendable (_ host: String, _ port: Int, _ emitWarning: (String) -> Void) -> Bool
    var detectExistingServerProcessIDs: @Sendable (_ host: String, _ port: Int) -> [Int]

    init(
        terminateExistingServer: @escaping @Sendable (
            _ host: String,
            _ port: Int,
            _ emitWarning: (String) -> Void
        ) -> Bool,
        detectExistingServerProcessIDs: @escaping @Sendable (_ host: String, _ port: Int) -> [Int]
    ) {
        self.terminateExistingServer = terminateExistingServer
        self.detectExistingServerProcessIDs = detectExistingServerProcessIDs
    }

    static let liveValue = live()

    static let testValue = Self(
        terminateExistingServer: { _, _, _ in false },
        detectExistingServerProcessIDs: { _, _ in [] }
    )

    static func live(
        clock: ClockClient = .liveValue,
        currentProcessID: @escaping @Sendable () -> Int = {
            Int(ProcessInfo.processInfo.processIdentifier)
        },
        processControl: ProcessControlClient = .liveValue
    ) -> Self {
        Self(
            terminateExistingServer: { host, port, emitWarning in
                terminateExistingProxyServerIfNeeded(
                    host: host,
                    port: port,
                    emitWarning: emitWarning,
                    clock: clock,
                    currentProcessID: currentProcessID,
                    processControl: processControl
                )
            },
            detectExistingServerProcessIDs: { host, port in
                detectExistingServerProcessIDs(
                    host: host,
                    port: port,
                    processControl: processControl
                )
            }
        )
    }

    private static func terminateExistingProxyServerIfNeeded(
        host: String,
        port: Int,
        emitWarning: (String) -> Void,
        clock: ClockClient,
        currentProcessID: @Sendable () -> Int,
        processControl: ProcessControlClient
    ) -> Bool {
        let processIDs = processControl.listeningProcessIDs(onTCPPort: port, matchingHost: host)
        guard !processIDs.isEmpty else { return false }

        let currentPID = currentProcessID()
        var didTerminate = false
        for processID in processIDs where processID != currentPID {
            guard isProxyServerProcess(pid: processID, processControl: processControl) else { continue }
            emitWarning(terminationWarning(port: port, pid: processID))
            if processControl.terminate(processID: processID, clock: clock) {
                didTerminate = true
            }
        }
        if didTerminate {
            processControl.waitForNoListeningProcesses(
                onTCPPort: port,
                matchingHost: host,
                timeout: 2.0,
                clock: clock
            )
        }
        return didTerminate
    }

    private static func detectExistingServerProcessIDs(
        host: String,
        port: Int,
        processControl: ProcessControlClient
    ) -> [Int] {
        // A cached discovery PID can be reused by a process serving a different endpoint.
        processControl.listeningProcessIDs(onTCPPort: port, matchingHost: host).filter {
            isProxyServerProcess(pid: $0, processControl: processControl)
        }
    }

    private static func terminationWarning(port: Int, pid: Int) -> String {
        "warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(pid)); terminating it."
    }

    private static func isProxyServerProcess(
        pid: Int,
        processControl: ProcessControlClient
    ) -> Bool {
        processControl.executableName(processID: pid) == "xcode-mcp-proxy-server"
    }
}
