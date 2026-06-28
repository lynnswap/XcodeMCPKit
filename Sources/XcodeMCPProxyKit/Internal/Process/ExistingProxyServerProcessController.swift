import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime

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
        discoveryClient: DiscoveryClient = .liveValue,
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
                    discoveryClient: discoveryClient,
                    clock: clock,
                    currentProcessID: currentProcessID,
                    processControl: processControl
                )
            },
            detectExistingServerProcessIDs: { host, port in
                detectExistingServerProcessIDs(
                    host: host,
                    port: port,
                    discoveryClient: discoveryClient,
                    processControl: processControl
                )
            }
        )
    }

    private static func terminateExistingProxyServerIfNeeded(
        host: String,
        port: Int,
        emitWarning: (String) -> Void,
        discoveryClient: DiscoveryClient,
        clock: ClockClient,
        currentProcessID: @Sendable () -> Int,
        processControl: ProcessControlClient
    ) -> Bool {
        if let record = discoveryClient.read(nil),
           record.port == port,
           ProcessControlClient.hostMatches(requestedHost: host, actualHost: record.host) {
            let currentPID = currentProcessID()
            if record.pid != currentPID,
               isProxyServerProcess(pid: record.pid, processControl: processControl) {
                emitWarning(terminationWarning(port: port, pid: record.pid))
                if processControl.terminate(processID: record.pid, clock: clock) {
                    processControl.waitForNoListeningProcesses(
                        onTCPPort: port,
                        matchingHost: host,
                        timeout: 2.0,
                        clock: clock
                    )
                    return true
                }
            }
        }

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
        discoveryClient: DiscoveryClient,
        processControl: ProcessControlClient
    ) -> [Int] {
        var processIDs: [Int] = []
        processIDs.reserveCapacity(4)

        if let record = discoveryClient.read(nil),
           record.port == port,
           ProcessControlClient.hostMatches(requestedHost: host, actualHost: record.host),
           isProxyServerProcess(pid: record.pid, processControl: processControl) {
            processIDs.append(record.pid)
        }

        for processID in processControl.listeningProcessIDs(onTCPPort: port, matchingHost: host)
        where isProxyServerProcess(pid: processID, processControl: processControl) {
            processIDs.append(processID)
        }

        var seen = Set<Int>()
        return processIDs.filter { seen.insert($0).inserted }
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
