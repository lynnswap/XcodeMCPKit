import Darwin
import Foundation
import Testing
import XcodeMCPCore

@testable import XcodeMCPProcessRuntime

@Suite
struct ProcessControlClientTests {
    @Test func hostMatchingHandlesLoopbackAndWildcard() throws {
        #expect(
            ProcessControlClient.hostMatches(
                requestedHost: "localhost",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            ProcessControlClient.hostMatches(
                requestedHost: "::",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            ProcessControlClient.hostMatches(
                requestedHost: "127.0.0.1",
                actualHost: "::1"
            ) == false
        )
    }

    @Test func extractsListeningPIDsFromLsofFieldOutputForLocalhost() throws {
        let output = """
        p51731
        f9
        n127.0.0.1:8765
        f13
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            ProcessControlClient.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "localhost"
            ) == [51731]
        )
    }

    @Test func extractsListeningPIDsFromLsofFieldOutputSkipsNonMatchingHosts() throws {
        let output = """
        p51731
        f9
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            ProcessControlClient.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "127.0.0.1"
            )
            .isEmpty
        )
    }

    @Test func extractsListeningPIDsFromLegacyTCPNames() throws {
        let output = """
        p111
        f9
        nTCP 127.0.0.1:8765 (LISTEN)
        p222
        f13
        nTCP [::1]:8765 (LISTEN)
        p333
        f8
        nTCP 10.0.0.5:8765 (LISTEN)
        """

        #expect(
            ProcessControlClient.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "localhost"
            ) == [111, 222]
        )
    }

    @Test func executableNameUsesFirstCommandTokenFromPSOutput() throws {
        let commandRecorder = CommandRecorder(
            outputs: [
                "/bin/ps|-ww -p 123 -o command=": "/tmp/xcode-mcp-proxy-server --flag\nignored\n",
            ]
        )
        let client = ProcessControlClient(
            runCommand: commandRecorder.runCommand,
            sendSignal: { _, _ in
                Issue.record("executable lookup should not send signals")
                return ProcessSignalResult(result: -1, errnoValue: ESRCH)
            }
        )

        #expect(client.executableName(processID: 123) == "xcode-mcp-proxy-server")
        #expect(
            commandRecorder.snapshot() == [
                CommandInvocation(launchPath: "/bin/ps", arguments: ["-ww", "-p", "123", "-o", "command="]),
            ]
        )
    }

    @Test func terminateSendsTermThenKillWhenProcessDoesNotExitAfterTerm() throws {
        let clock = ManualClock()
        let signals = SignalRecorder()
        let client = ProcessControlClient(
            runCommand: { _, _ in nil },
            sendSignal: signals.sendSignal
        )

        #expect(client.terminate(processID: 42, clock: clock.client))
        let sentSignals = signals.snapshot().map(\.signal)
        #expect(sentSignals.first == 0)
        #expect(sentSignals.contains(SIGTERM))
        #expect(sentSignals.contains(SIGKILL))
        #expect(clock.sleepIntervals().contains(0.05))
    }

    @Test func waitForNoListeningProcessesPollsUntilLsofReturnsNoMatches() throws {
        let outputWithListener = """
        p51731
        f9
        n127.0.0.1:8765
        """
        let commandRecorder = CommandRecorder(
            outputs: [
                "/usr/sbin/lsof|-nP -iTCP:8765 -sTCP:LISTEN -Fpn": outputWithListener,
            ],
            defaultOutput: ""
        )
        let clock = ManualClock()
        let client = ProcessControlClient(
            runCommand: commandRecorder.runCommand,
            sendSignal: { _, _ in ProcessSignalResult(result: -1, errnoValue: ESRCH) }
        )

        #expect(
            client.waitForNoListeningProcesses(
                onTCPPort: 8765,
                matchingHost: "localhost",
                timeout: 2.0,
                clock: clock.client
            )
        )
        #expect(commandRecorder.snapshot().count == 2)
        #expect(clock.sleepIntervals() == [0.05])
    }
}

private struct CommandInvocation: Equatable, Sendable {
    let launchPath: String
    let arguments: [String]
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String: [String]]
    private let defaultOutput: String?
    private var invocations: [CommandInvocation] = []

    init(outputs: [String: String], defaultOutput: String? = nil) {
        self.outputs = outputs.mapValues { [$0] }
        self.defaultOutput = defaultOutput
    }

    func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        lock.withLock {
            invocations.append(CommandInvocation(launchPath: launchPath, arguments: arguments))
            let key = Self.key(launchPath: launchPath, arguments: arguments)
            guard var values = outputs[key], values.isEmpty == false else {
                return defaultOutput
            }
            let output = values.removeFirst()
            outputs[key] = values
            return output
        }
    }

    func snapshot() -> [CommandInvocation] {
        lock.withLock { invocations }
    }

    private static func key(launchPath: String, arguments: [String]) -> String {
        "\(launchPath)|\(arguments.joined(separator: " "))"
    }
}

private struct SignalInvocation: Sendable {
    let processID: Int
    let signal: Int32
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [SignalInvocation] = []
    private var isAlive = true

    func sendSignal(processID: Int, signal: Int32) -> ProcessSignalResult {
        lock.withLock {
            invocations.append(SignalInvocation(processID: processID, signal: signal))
            if signal == SIGKILL {
                isAlive = false
                return ProcessSignalResult(result: 0, errnoValue: 0)
            }
            if signal == 0, !isAlive {
                return ProcessSignalResult(result: -1, errnoValue: ESRCH)
            }
            return ProcessSignalResult(result: 0, errnoValue: 0)
        }
    }

    func snapshot() -> [SignalInvocation] {
        lock.withLock { invocations }
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime = Date(timeIntervalSince1970: 0)
    private var sleeps: [TimeInterval] = []

    var client: ClockClient {
        ClockClient(
            now: { self.now() },
            uptimeNanoseconds: { 0 },
            sleep: { _ in },
            sleepForTimeInterval: { interval in
                self.sleep(interval)
            }
        )
    }

    func sleepIntervals() -> [TimeInterval] {
        lock.withLock { sleeps }
    }

    private func now() -> Date {
        lock.withLock { currentTime }
    }

    private func sleep(_ interval: TimeInterval) {
        lock.withLock {
            sleeps.append(interval)
            currentTime = currentTime.addingTimeInterval(interval)
        }
    }
}
