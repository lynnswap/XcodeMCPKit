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

        private enum Phase {
            case ready
            case running(TaskRecord)
            case closing(TaskRecord)
            case closed
        }

        private actor Worker {
            private var scanner: PermissionDialogScanner

            init(scanner: PermissionDialogScanner) {
                self.scanner = scanner
            }

            func scan() -> PermissionDialogScanner.ScanResult {
                scanner.scanAndApprove()
            }
        }

        private let configuration: XcodePermissionDialogAutomation.Configuration
        private let dependencies: Dependencies
        private let worker: Worker
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
            self.worker = Worker(
                scanner: PermissionDialogScanner(
                    dependencies: .init(
                        configuration: configuration,
                        axClient: dependencies.axClient,
                        uptimeNanoseconds: dependencies.uptimeNanoseconds,
                        logger: dependencies.logger
                    )
                )
            )
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
                let worker = worker
                let interval = configuration.pollInterval
                let sleep = dependencies.sleep
                let logger = dependencies.logger
                let task = Task {
                    while Task.isCancelled == false {
                        _ = await worker.scan()
                        do {
                            try await sleep(interval)
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error(
                                "Xcode permission-dialog auto-approver polling stopped after an unexpected clock failure.",
                                metadata: ["error": .string(String(describing: error))]
                            )
                            break
                        }
                    }
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
