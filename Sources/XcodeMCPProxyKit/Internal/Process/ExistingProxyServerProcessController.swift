import Darwin
import Foundation
import ProxyCore
import XcodeMCPRuntime

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
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String? =
            defaultRunCommand,
        sendSignal: @escaping @Sendable (_ pid: Int, _ signal: Int32) -> SignalResult = defaultSendSignal
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
                    runCommand: runCommand,
                    sendSignal: sendSignal
                )
            },
            detectExistingServerProcessIDs: { host, port in
                detectExistingServerProcessIDs(
                    host: host,
                    port: port,
                    discoveryClient: discoveryClient,
                    runCommand: runCommand
                )
            }
        )
    }

    struct SignalResult: Sendable {
        let result: Int32
        let errnoValue: Int32

        init(result: Int32, errnoValue: Int32) {
            self.result = result
            self.errnoValue = errnoValue
        }
    }

    static func hostMatches(requestedHost: String, actualHost: String) -> Bool {
        let requested = normalizeHost(requestedHost)
        let actual = normalizeHost(actualHost)

        if isWildcardHost(requested) { return true }
        if isWildcardHost(actual) { return true }

        if requested == "localhost" {
            return actual == "localhost" || actual == "127.0.0.1" || actual == "::1"
        }
        if actual == "localhost" {
            return requested == "localhost" || requested == "127.0.0.1" || requested == "::1"
        }

        return requested == actual
    }

    static func listeningProcessIDs(fromLsofOutput output: String, matchingHost host: String) -> [Int] {
        let matchAllHosts = isWildcardHost(host)

        var processIDs: [Int] = []
        processIDs.reserveCapacity(4)

        var currentProcessID: Int?
        var currentMatched = matchAllHosts

        func flush() {
            if let currentProcessID, currentMatched {
                processIDs.append(currentProcessID)
            }
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let first = rawLine.first else { continue }
            if first == "p" {
                flush()
                currentProcessID = Int(rawLine.dropFirst())
                currentMatched = matchAllHosts
                continue
            }
            if first == "n", !matchAllHosts {
                let name = String(rawLine.dropFirst())
                if let listenerHost = extractListenerHost(fromLsofName: name),
                   hostMatches(requestedHost: host, actualHost: listenerHost) {
                    currentMatched = true
                }
            }
        }
        flush()

        var seen = Set<Int>()
        return processIDs.filter { seen.insert($0).inserted }
    }

    private static func terminateExistingProxyServerIfNeeded(
        host: String,
        port: Int,
        emitWarning: (String) -> Void,
        discoveryClient: DiscoveryClient,
        clock: ClockClient,
        currentProcessID: @Sendable () -> Int,
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String?,
        sendSignal: @escaping @Sendable (_ pid: Int, _ signal: Int32) -> SignalResult
    ) -> Bool {
        if let record = discoveryClient.read(nil),
           record.port == port,
           hostMatches(requestedHost: host, actualHost: record.host) {
            let currentPID = currentProcessID()
            if record.pid != currentPID,
               isProxyServerProcess(pid: record.pid, runCommand: runCommand) {
                emitWarning(terminationWarning(port: port, pid: record.pid))
                if terminate(pid: record.pid, clock: clock, sendSignal: sendSignal) {
                    waitForPortToBeFree(
                        host: host,
                        port: port,
                        timeout: 2.0,
                        clock: clock,
                        runCommand: runCommand
                    )
                    return true
                }
            }
        }

        let processIDs = listeningProcessIDs(onTCPPort: port, matchingHost: host, runCommand: runCommand)
        guard !processIDs.isEmpty else { return false }

        let currentPID = currentProcessID()
        var didTerminate = false
        for processID in processIDs where processID != currentPID {
            guard isProxyServerProcess(pid: processID, runCommand: runCommand) else { continue }
            emitWarning(terminationWarning(port: port, pid: processID))
            if terminate(pid: processID, clock: clock, sendSignal: sendSignal) {
                didTerminate = true
            }
        }
        if didTerminate {
            waitForPortToBeFree(
                host: host,
                port: port,
                timeout: 2.0,
                clock: clock,
                runCommand: runCommand
            )
        }
        return didTerminate
    }

    private static func detectExistingServerProcessIDs(
        host: String,
        port: Int,
        discoveryClient: DiscoveryClient,
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String?
    ) -> [Int] {
        var processIDs: [Int] = []
        processIDs.reserveCapacity(4)

        if let record = discoveryClient.read(nil),
           record.port == port,
           hostMatches(requestedHost: host, actualHost: record.host),
           isProxyServerProcess(pid: record.pid, runCommand: runCommand) {
            processIDs.append(record.pid)
        }

        for processID in listeningProcessIDs(onTCPPort: port, matchingHost: host, runCommand: runCommand)
        where isProxyServerProcess(pid: processID, runCommand: runCommand) {
            processIDs.append(processID)
        }

        var seen = Set<Int>()
        return processIDs.filter { seen.insert($0).inserted }
    }

    private static func terminationWarning(port: Int, pid: Int) -> String {
        "warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(pid)); terminating it."
    }

    private static func firstLine(_ output: String?) -> String? {
        guard let output else { return nil }
        return output.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value.lowercased()
    }

    private static func isWildcardHost(_ host: String) -> Bool {
        let value = normalizeHost(host)
        return value.isEmpty || value == "*" || value == "0.0.0.0" || value == "::"
    }

    private static func extractListenerHost(fromLsofName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let endpointSource: Substring
        if trimmed.hasPrefix("TCP ") {
            endpointSource = trimmed.dropFirst(4)
        } else {
            endpointSource = trimmed[...]
        }

        guard let endpoint = endpointSource.split(whereSeparator: \.isWhitespace).first else { return nil }
        let endpointString = String(endpoint)
        if endpointString.hasPrefix("["),
           let close = endpointString.firstIndex(of: "]") {
            let start = endpointString.index(after: endpointString.startIndex)
            return String(endpointString[start..<close])
        }
        guard let colon = endpointString.lastIndex(of: ":") else { return nil }
        return String(endpointString[..<colon])
    }

    private static func listeningProcessIDs(
        onTCPPort port: Int,
        matchingHost host: String,
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String?
    ) -> [Int] {
        guard let output = runCommand(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return []
        }

        return listeningProcessIDs(fromLsofOutput: output, matchingHost: host)
    }

    private static func isProxyServerProcess(
        pid: Int,
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String?
    ) -> Bool {
        guard pid > 0 else { return false }
        guard
            let commandLine = firstLine(
                runCommand("/bin/ps", ["-ww", "-p", "\(pid)", "-o", "command="])
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !commandLine.isEmpty,
            let executable = commandLine.split(whereSeparator: \.isWhitespace).first.map(String.init),
            !executable.isEmpty
        else {
            return false
        }
        return URL(fileURLWithPath: executable).lastPathComponent == "xcode-mcp-proxy-server"
    }

    private static func terminate(
        pid: Int,
        clock: ClockClient,
        sendSignal: @escaping @Sendable (_ pid: Int, _ signal: Int32) -> SignalResult
    ) -> Bool {
        guard pid > 0 else { return false }
        if !isProcessAlive(pid, sendSignal: sendSignal) {
            return true
        }

        let termResult = sendSignal(pid, SIGTERM)
        if termResult.result != 0, termResult.errnoValue != ESRCH {
            return false
        }
        if waitForProcessExit(pid: pid, timeout: 1.0, clock: clock, sendSignal: sendSignal) {
            return true
        }

        let killResult = sendSignal(pid, SIGKILL)
        if killResult.result != 0, killResult.errnoValue != ESRCH {
            return false
        }
        return waitForProcessExit(pid: pid, timeout: 1.0, clock: clock, sendSignal: sendSignal)
    }

    private static func isProcessAlive(
        _ pid: Int,
        sendSignal: @escaping @Sendable (_ pid: Int, _ signal: Int32) -> SignalResult
    ) -> Bool {
        guard pid > 0 else { return false }
        let result = sendSignal(pid, 0)
        if result.result == 0 {
            return true
        }
        return result.errnoValue == EPERM
    }

    private static func waitForProcessExit(
        pid: Int,
        timeout: TimeInterval,
        clock: ClockClient,
        sendSignal: @escaping @Sendable (_ pid: Int, _ signal: Int32) -> SignalResult
    ) -> Bool {
        let deadline = clock.now().addingTimeInterval(timeout)
        while clock.now() < deadline {
            if !isProcessAlive(pid, sendSignal: sendSignal) {
                return true
            }
            clock.sleepForTimeInterval(0.05)
        }
        return !isProcessAlive(pid, sendSignal: sendSignal)
    }

    private static func waitForPortToBeFree(
        host: String,
        port: Int,
        timeout: TimeInterval,
        clock: ClockClient,
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String?
    ) {
        let deadline = clock.now().addingTimeInterval(timeout)
        while clock.now() < deadline {
            if listeningProcessIDs(onTCPPort: port, matchingHost: host, runCommand: runCommand).isEmpty {
                return
            }
            clock.sleepForTimeInterval(0.05)
        }
    }

    private static func defaultRunCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func defaultSendSignal(pid: Int, signal: Int32) -> SignalResult {
        errno = 0
        let result = kill(pid_t(pid), signal)
        return SignalResult(result: result, errnoValue: errno)
    }
}
