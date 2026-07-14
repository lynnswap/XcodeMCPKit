import Darwin
import Foundation
import Logging

extension XcodePermissionDialogAutomation {
    package struct Configuration: Sendable {
        let permissionDialogProcessIDs: @Sendable () -> [pid_t]
        let agentPathCandidates: @Sendable () -> Set<String>
        let assistantNameCandidates: @Sendable () -> Set<String>
        let agentProcessIDCandidates: @Sendable () -> Set<pid_t>
        let pollInterval: Duration

        package init(
            permissionDialogProcessIDs: @escaping @Sendable () -> [pid_t],
            agentPathCandidates: @escaping @Sendable () -> Set<String>,
            assistantNameCandidates: @escaping @Sendable () -> Set<String>,
            agentProcessIDCandidates: @escaping @Sendable () -> Set<pid_t>,
            pollInterval: Duration = .milliseconds(250)
        ) {
            precondition(pollInterval > .zero, "pollInterval must be positive")
            self.permissionDialogProcessIDs = permissionDialogProcessIDs
            self.agentPathCandidates = agentPathCandidates
            self.assistantNameCandidates = assistantNameCandidates
            self.agentProcessIDCandidates = agentProcessIDCandidates
            self.pollInterval = pollInterval
        }
    }

    package final class AutoApprover: @unchecked Sendable {
        struct Dependencies: Sendable {
            let axClient: any XcodePermissionDialogAutomation.AXAccessing
            let sleep: @Sendable (Duration) async throws -> Void
            let uptimeNanoseconds: @Sendable () -> UInt64
            let logger: Logger

            static func live(logger: Logger) -> Self {
                let clock = ContinuousClock()
                return Self(
                    axClient: XcodePermissionDialogAutomation.AXClient(),
                    sleep: { duration in
                        try await clock.sleep(for: duration)
                    },
                    uptimeNanoseconds: {
                        DispatchTime.now().uptimeNanoseconds
                    },
                    logger: logger
                )
            }
        }

        private struct TaskRecord {
            let id: UInt64
            let task: Task<Void, Never>
        }

        private struct ProcessMonitor {
            let task: Task<Void, Never>
            let completion: ProcessMonitorCompletion
        }

        private final class ProcessMonitorCompletion: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false

            var isFinished: Bool {
                lock.withLock { finished }
            }

            func finish() {
                lock.withLock {
                    finished = true
                }
            }
        }

        private enum Phase {
            case ready
            case running(TaskRecord)
            case closing(TaskRecord)
            case closed
        }

        private let configuration: XcodePermissionDialogAutomation.Configuration
        private let dependencies: Dependencies
        private let scannerSharedState = PermissionDialogScanner.SharedState()
        private let stateLock = NSLock()
        private var phase: Phase = .ready
        private var nextTaskID: UInt64 = 0

        package convenience init(
            configuration: XcodePermissionDialogAutomation.Configuration,
            logger: Logger
        ) {
            self.init(
                configuration: configuration,
                dependencies: .live(logger: logger)
            )
        }

        init(
            configuration: XcodePermissionDialogAutomation.Configuration,
            dependencies: Dependencies
        ) {
            self.configuration = configuration
            self.dependencies = dependencies
        }

        deinit {
            cancel()
        }

        package func start() {
            stateLock.withLock {
                guard case .ready = phase else {
                    return
                }

                nextTaskID &+= 1
                let taskID = nextTaskID
                let configuration = configuration
                let dependencies = dependencies
                let scannerSharedState = scannerSharedState
                let task = Task {
                    await Self.runProcessMonitorSupervisor(
                        configuration: configuration,
                        dependencies: dependencies,
                        scannerSharedState: scannerSharedState
                    )
                }
                phase = .running(TaskRecord(id: taskID, task: task))
            }
        }

        package func shutdown() async {
            let record: TaskRecord? = stateLock.withLock {
                switch phase {
                case .ready:
                    phase = .closed
                    return nil
                case .running(let record):
                    phase = .closing(record)
                    return record
                case .closing(let record):
                    return record
                case .closed:
                    return nil
                }
            }

            record?.task.cancel()
            await record?.task.value

            guard let record else {
                return
            }
            stateLock.withLock {
                guard case .closing(let current) = phase, current.id == record.id else {
                    return
                }
                phase = .closed
            }
        }

        package func cancel() {
            let task: Task<Void, Never>? = stateLock.withLock {
                let task: Task<Void, Never>?
                switch phase {
                case .ready, .closed:
                    task = nil
                case .running(let record), .closing(let record):
                    task = record.task
                }
                phase = .closed
                return task
            }
            task?.cancel()
        }

        private static func runProcessMonitorSupervisor(
            configuration: XcodePermissionDialogAutomation.Configuration,
            dependencies: Dependencies,
            scannerSharedState: PermissionDialogScanner.SharedState
        ) async {
            var monitors: [pid_t: ProcessMonitor] = [:]

            if dependencies.axClient.authorizationStatus(promptIfNeeded: false) != .trusted {
                scannerSharedState.requestAccessibilityPermissionIfNeeded(
                    axClient: dependencies.axClient,
                    logger: dependencies.logger
                )
            }

            while Task.isCancelled == false {
                let processIDs = Set(
                    configuration.permissionDialogProcessIDs().filter { $0 > 0 }
                )

                let completedProcessIDs = monitors.compactMap { processID, monitor in
                    monitor.completion.isFinished ? processID : nil
                }
                for processID in completedProcessIDs {
                    guard let monitor = monitors.removeValue(forKey: processID) else {
                        continue
                    }
                    await monitor.task.value
                }

                for processID in Array(monitors.keys)
                where processIDs.contains(processID) == false {
                    monitors[processID]?.task.cancel()
                }

                let addedProcessIDs = processIDs.filter { monitors[$0] == nil }.sorted()
                for processID in addedProcessIDs {
                    monitors[processID] = makeProcessMonitor(
                        processID: processID,
                        configuration: configuration,
                        dependencies: dependencies,
                        scannerSharedState: scannerSharedState
                    )
                }

                do {
                    try await dependencies.sleep(configuration.pollInterval)
                } catch is CancellationError {
                    break
                } catch {
                    dependencies.logger.error(
                        "Xcode permission-dialog process monitor stopped after an unexpected clock failure.",
                        metadata: ["error": .string(String(describing: error))]
                    )
                    break
                }
            }

            let activeMonitors = monitors.values.map(\.task)
            for monitor in activeMonitors {
                monitor.cancel()
            }
            for monitor in activeMonitors {
                await monitor.value
            }
        }

        private static func makeProcessMonitor(
            processID: pid_t,
            configuration: XcodePermissionDialogAutomation.Configuration,
            dependencies: Dependencies,
            scannerSharedState: PermissionDialogScanner.SharedState
        ) -> ProcessMonitor {
            let completion = ProcessMonitorCompletion()
            let task = Task {
                defer { completion.finish() }
                var scanner = PermissionDialogScanner(
                    dependencies: .init(
                        configuration: configuration,
                        axClient: dependencies.axClient,
                        uptimeNanoseconds: dependencies.uptimeNanoseconds,
                        logger: dependencies.logger,
                        sharedState: scannerSharedState
                    )
                )

                while Task.isCancelled == false {
                    _ = scanner.scanAndApprove(processIDs: [processID])
                    do {
                        try await dependencies.sleep(configuration.pollInterval)
                    } catch is CancellationError {
                        break
                    } catch {
                        dependencies.logger.error(
                            "Xcode permission-dialog PID monitor stopped after an unexpected clock failure.",
                            metadata: [
                                "pid": .string("\(processID)"),
                                "error": .string(String(describing: error)),
                            ]
                        )
                        break
                    }
                }
            }
            return ProcessMonitor(task: task, completion: completion)
        }

        package static func executablePathCandidates(
            arguments: [String] = CommandLine.arguments,
            executableURL: URL? = Bundle.main.executableURL,
            additional: [String] = []
        ) -> Set<String> {
            var candidates: Set<String> = []

            if let raw = arguments.first, raw.isEmpty == false {
                candidates.insert(raw)
                let rawURL = URL(fileURLWithPath: raw)
                candidates.insert(rawURL.standardizedFileURL.path)
                candidates.insert(rawURL.resolvingSymlinksInPath().path)
            }

            if let executablePath = executableURL?.path, executablePath.isEmpty == false {
                let executableURL = URL(fileURLWithPath: executablePath)
                candidates.insert(executablePath)
                candidates.insert(executableURL.standardizedFileURL.path)
                candidates.insert(executableURL.resolvingSymlinksInPath().path)
            }

            for candidate in additional where candidate.isEmpty == false {
                let candidateURL = URL(fileURLWithPath: candidate)
                candidates.insert(candidate)
                candidates.insert(candidateURL.standardizedFileURL.path)
                candidates.insert(candidateURL.resolvingSymlinksInPath().path)
            }

            return Set(candidates.filter { $0.isEmpty == false })
        }

        package static func descendantProcessIDCandidates(
            of processID: pid_t = ProcessInfo.processInfo.processIdentifier
        ) -> Set<pid_t> {
            var candidates: Set<pid_t> = [processID]
            var pending = [processID]

            while let currentProcessID = pending.popLast() {
                for childProcessID in childProcessIDs(of: currentProcessID)
                where candidates.insert(childProcessID).inserted {
                    pending.append(childProcessID)
                }
            }

            return candidates
        }

        private static func childProcessIDs(of parentProcessID: pid_t) -> [pid_t] {
            let childCount = max(0, proc_listchildpids(parentProcessID, nil, 0))
            guard childCount > 0 else {
                return []
            }

            var processIDs = [pid_t](repeating: 0, count: Int(childCount))
            let copiedCount = processIDs.withUnsafeMutableBufferPointer { buffer in
                unsafe proc_listchildpids(
                    parentProcessID,
                    buffer.baseAddress,
                    Int32(buffer.count * MemoryLayout<pid_t>.stride)
                )
            }
            guard copiedCount > 0 else {
                return []
            }

            return processIDs.prefix(Int(copiedCount)).filter { $0 > 0 }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
