import AppKit
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import Logging
import XcodeMCPPermissionAutomation

@main
struct XcodeMCPPermissionApproverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-mcp-permission-approver",
        abstract: "Approve Xcode MCP permission dialogs for explicit process identities.",
        discussion: """
            This maintainer diagnostic monitors existing processes only. It does not launch
            xcode-mcp-proxy-server, mcpbridge, or any other child process.
            """
    )

    @Option(
        name: .customLong("xcode-pid"),
        help: "Running Xcode or known Xcode permission-helper PID. May be repeated."
    )
    var xcodeProcessIDs: [Int32] = []

    @Option(
        name: .customLong("agent-pid"),
        help: "Running proxy/agent PID whose process tree owns the dialog. May be repeated."
    )
    var agentProcessIDs: [Int32] = []

    @Option(
        name: .customLong("agent-path"),
        help: "Exact proxy/agent executable path shown by Xcode. May be repeated."
    )
    var agentPaths: [String] = []

    @Option(
        name: .customLong("assistant-name"),
        help: "Exact assistant name shown by Xcode. May be repeated."
    )
    var assistantNames: [String] = []

    mutating func validate() throws {
        guard xcodeProcessIDs.isEmpty == false else {
            throw ValidationError("at least one --xcode-pid is required")
        }
        guard agentProcessIDs.isEmpty == false else {
            throw ValidationError("at least one --agent-pid is required")
        }
        guard xcodeProcessIDs.allSatisfy({ $0 > 0 }) else {
            throw ValidationError("--xcode-pid values must be positive")
        }
        guard agentProcessIDs.allSatisfy({ $0 > 0 }) else {
            throw ValidationError("--agent-pid values must be positive")
        }

        agentPaths = agentPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        assistantNames = assistantNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard
            agentPaths.contains(where: { $0.isEmpty == false })
                || assistantNames.contains(where: { $0.isEmpty == false })
        else {
            throw ValidationError(
                "at least one non-empty --agent-path or --assistant-name is required"
            )
        }
    }

    mutating func run() async throws {
        let xcodeProcessIDs: Set<pid_t> = Set(self.xcodeProcessIDs)
        let rootAgentProcessIDs: Set<pid_t> = Set(self.agentProcessIDs)
        let agentPathCandidates = XcodePermissionDialogAutomation.AutoApprover
            .executablePathCandidates(
                arguments: [],
                executableURL: nil,
                additional: agentPaths
            )
        let assistantNameCandidates = Set(assistantNames.filter { $0.isEmpty == false })

        try Self.validateXcodeProcesses(xcodeProcessIDs) { processID in
            guard let application = NSRunningApplication(processIdentifier: processID),
                application.isTerminated == false
            else {
                return nil
            }
            return application.bundleIdentifier
        }
        try Self.validateAgentProcesses(rootAgentProcessIDs) { processID in
            errno = 0
            let result = kill(processID, 0)
            return result == 0 || errno == EPERM
        }

        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
        let logger = Logger(label: "XcodeMCPPermissionApprover")
        let approver = XcodePermissionDialogAutomation.AutoApprover(
            configuration: .init(
                permissionDialogProcessIDs: { xcodeProcessIDs.sorted() },
                agentPathCandidates: { agentPathCandidates },
                assistantNameCandidates: { assistantNameCandidates },
                agentProcessIDCandidates: {
                    rootAgentProcessIDs.reduce(into: Set<pid_t>()) { candidates, processID in
                        candidates.formUnion(
                            XcodePermissionDialogAutomation.AutoApprover
                                .descendantProcessIDCandidates(of: processID)
                        )
                    }
                }
            ),
            logger: logger
        )
        let terminationSignal = TerminationSignal()
        approver.start()

        logger.info(
            "Monitoring explicit Xcode MCP permission-dialog candidates.",
            metadata: [
                "xcode_pids": .string(xcodeProcessIDs.map(String.init).sorted().joined(separator: ",")),
                "agent_pids": .string(rootAgentProcessIDs.map(String.init).sorted().joined(separator: ",")),
            ]
        )

        await terminationSignal.wait()
        terminationSignal.cancel()
        await approver.shutdown()
    }

    static func validateXcodeProcesses(
        _ processIDs: Set<pid_t>,
        bundleIdentifier: (pid_t) -> String?
    ) throws {
        for processID in processIDs {
            guard
                XcodePermissionDialogAutomation.isAllowedProcessBundleIdentifier(
                    bundleIdentifier(processID)
                )
            else {
                throw ValidationError(
                    "--xcode-pid \(processID) is not a running Xcode or known permission helper"
                )
            }
        }
    }

    static func validateAgentProcesses(
        _ processIDs: Set<pid_t>,
        isRunning: (pid_t) -> Bool
    ) throws {
        for processID in processIDs {
            guard isRunning(processID) else {
                throw ValidationError("--agent-pid \(processID) is not running")
            }
        }
    }
}

private final class TerminationSignal: @unchecked Sendable {
    private struct State {
        var didTerminate = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let lock = NSLock()
    private var state = State()
    private let sources: [any DispatchSourceSignal]

    init() {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        self.sources = [interruptSource, terminateSource]

        for source in sources {
            source.setEventHandler { [weak self] in
                self?.finish()
            }
            source.resume()
        }
    }

    deinit {
        cancel()
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if state.didTerminate {
                        return true
                    }
                    precondition(state.continuation == nil, "TerminationSignal supports one waiter")
                    state.continuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.finish()
        }
    }

    func cancel() {
        for source in sources {
            source.cancel()
        }
        finish()
    }

    private func finish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard state.didTerminate == false else {
                return nil
            }
            state.didTerminate = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
