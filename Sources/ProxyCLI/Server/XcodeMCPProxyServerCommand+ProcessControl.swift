import Darwin
import Foundation
import XcodeMCPProxy

extension XcodeMCPProxyServerCommand {
    package static func hostMatches(requestedHost: String, actualHost: String) -> Bool {
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

    @discardableResult
    static func terminateExistingProxyServerIfNeeded(host: String, port: Int) -> Bool {
        if let record = Discovery.read(),
           record.port == port,
           hostMatches(requestedHost: host, actualHost: record.host) {
            let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
            if record.pid != currentPID, isProxyServerProcess(pid: record.pid) {
                FileHandle.writeLine(
                    "warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(record.pid)); terminating it.",
                    to: .standardError
                )
                if terminate(pid: record.pid) {
                    waitForPortToBeFree(host: host, port: port, timeout: 2.0)
                    return true
                }
            }
        }

        let pids = listeningPIDs(onTCPPort: port, matchingHost: host)
        guard !pids.isEmpty else { return false }

        let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
        var didTerminate = false
        for pid in pids where pid != currentPID {
            guard isProxyServerProcess(pid: pid) else { continue }
            FileHandle.writeLine(
                "warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(pid)); terminating it.",
                to: .standardError
            )
            if terminate(pid: pid) {
                didTerminate = true
            }
        }
        if didTerminate {
            waitForPortToBeFree(host: host, port: port, timeout: 2.0)
        }
        return didTerminate
    }

    static func detectExistingProxyServerPIDs(host: String, port: Int) -> [Int] {
        var pids: [Int] = []
        pids.reserveCapacity(4)

        if let record = Discovery.read(),
           record.port == port,
           hostMatches(requestedHost: host, actualHost: record.host),
           isProxyServerProcess(pid: record.pid) {
            pids.append(record.pid)
        }

        for pid in listeningPIDs(onTCPPort: port, matchingHost: host) where isProxyServerProcess(pid: pid) {
            pids.append(pid)
        }

        var seen = Set<Int>()
        return pids.filter { seen.insert($0).inserted }
    }

    private static func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
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

    private static func listeningPIDs(onTCPPort port: Int, matchingHost host: String) -> [Int] {
        guard let output = runCommand(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return []
        }

        return listeningPIDs(fromLsofOutput: output, matchingHost: host)
    }

    package static func listeningPIDs(fromLsofOutput output: String, matchingHost host: String) -> [Int] {
        let matchAllHosts = isWildcardHost(host)

        var pids: [Int] = []
        pids.reserveCapacity(4)

        var currentPID: Int?
        var currentMatched = matchAllHosts

        func flush() {
            if let pid = currentPID, currentMatched {
                pids.append(pid)
            }
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let first = rawLine.first else { continue }
            if first == "p" {
                flush()
                currentPID = Int(rawLine.dropFirst())
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
        return pids.filter { seen.insert($0).inserted }
    }

    private static func isProxyServerProcess(pid: Int) -> Bool {
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

    private static func terminate(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if !isProcessAlive(pid) {
            return true
        }

        let termResult = kill(pid_t(pid), SIGTERM)
        if termResult != 0, errno != ESRCH {
            return false
        }
        if waitForProcessExit(pid: pid, timeout: 1.0) {
            return true
        }

        let killResult = kill(pid_t(pid), SIGKILL)
        if killResult != 0, errno != ESRCH {
            return false
        }
        return waitForProcessExit(pid: pid, timeout: 1.0)
    }

    private static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid_t(pid), 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func waitForProcessExit(pid: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessAlive(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isProcessAlive(pid)
    }

    private static func waitForPortToBeFree(host: String, port: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listeningPIDs(onTCPPort: port, matchingHost: host).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
