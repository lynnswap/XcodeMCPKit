import Darwin
import Foundation

package struct ProcessSignalResult: Sendable {
    package let result: Int32
    package let errnoValue: Int32

    package init(result: Int32, errnoValue: Int32) {
        self.result = result
        self.errnoValue = errnoValue
    }
}

package struct ProcessControlClient: Sendable {
    package var runCommand: @Sendable (_ launchPath: String, _ arguments: [String]) -> String?
    package var sendSignal: @Sendable (_ processID: Int, _ signal: Int32) -> ProcessSignalResult

    package init(
        runCommand: @escaping @Sendable (_ launchPath: String, _ arguments: [String]) -> String?,
        sendSignal: @escaping @Sendable (_ processID: Int, _ signal: Int32) -> ProcessSignalResult
    ) {
        self.runCommand = runCommand
        self.sendSignal = sendSignal
    }

    package static let liveValue = Self(
        runCommand: defaultRunCommand,
        sendSignal: defaultSendSignal
    )

    package func commandLine(processID: Int) -> String? {
        guard processID > 0 else { return nil }
        return Self.firstLine(
            runCommand("/bin/ps", ["-ww", "-p", "\(processID)", "-o", "command="])
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func executablePath(processID: Int) -> String? {
        guard
            let commandLine = commandLine(processID: processID),
            !commandLine.isEmpty,
            let executable = commandLine.split(whereSeparator: \.isWhitespace).first.map(String.init),
            !executable.isEmpty
        else {
            return nil
        }
        return executable
    }

    package func executableName(processID: Int) -> String? {
        guard let executablePath = executablePath(processID: processID) else {
            return nil
        }
        return URL(fileURLWithPath: executablePath).lastPathComponent
    }

    package func listeningProcessIDs(onTCPPort port: Int, matchingHost host: String) -> [Int] {
        guard let output = runCommand(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return []
        }

        return Self.listeningProcessIDs(fromLsofOutput: output, matchingHost: host)
    }

    @discardableResult
    package func waitForNoListeningProcesses(
        onTCPPort port: Int,
        matchingHost host: String,
        timeout: TimeInterval,
        clock: ClockClient
    ) -> Bool {
        let deadline = clock.now().addingTimeInterval(timeout)
        while clock.now() < deadline {
            if listeningProcessIDs(onTCPPort: port, matchingHost: host).isEmpty {
                return true
            }
            clock.sleepForTimeInterval(0.05)
        }
        return listeningProcessIDs(onTCPPort: port, matchingHost: host).isEmpty
    }

    package func terminate(processID: Int, clock: ClockClient) -> Bool {
        guard processID > 0 else { return false }
        if !isProcessAlive(processID) {
            return true
        }

        let termResult = sendSignal(processID, SIGTERM)
        if termResult.result != 0, termResult.errnoValue != ESRCH {
            return false
        }
        if waitForProcessExit(processID: processID, timeout: 1.0, clock: clock) {
            return true
        }

        let killResult = sendSignal(processID, SIGKILL)
        if killResult.result != 0, killResult.errnoValue != ESRCH {
            return false
        }
        return waitForProcessExit(processID: processID, timeout: 1.0, clock: clock)
    }

    package func isProcessAlive(_ processID: Int) -> Bool {
        guard processID > 0 else { return false }
        let result = sendSignal(processID, 0)
        if result.result == 0 {
            return true
        }
        return result.errnoValue == EPERM
    }

    package func waitForProcessExit(
        processID: Int,
        timeout: TimeInterval,
        clock: ClockClient
    ) -> Bool {
        let deadline = clock.now().addingTimeInterval(timeout)
        while clock.now() < deadline {
            if !isProcessAlive(processID) {
                return true
            }
            clock.sleepForTimeInterval(0.05)
        }
        return !isProcessAlive(processID)
    }

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

    package static func listeningProcessIDs(fromLsofOutput output: String, matchingHost host: String) -> [Int] {
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

    private static func defaultSendSignal(processID: Int, signal: Int32) -> ProcessSignalResult {
        errno = 0
        let result = kill(pid_t(processID), signal)
        return ProcessSignalResult(result: result, errnoValue: errno)
    }
}
