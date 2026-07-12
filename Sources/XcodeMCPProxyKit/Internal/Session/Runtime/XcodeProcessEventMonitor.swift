import Foundation
import XcodeMCPKit

#if canImport(AppKit)
import AppKit
#endif

protocol XcodeProcessEventMonitoring: XcodeTargetDiscovering {
    func start()
    func setChangeHandler(
        _ handler: @escaping @Sendable (_ reason: String) -> Void
    )
    func permissionDialogProcessIDs() -> [pid_t]
    func readinessSnapshot() -> UpstreamReadinessSnapshot
    func waitForReadinessChange(after generation: UInt64) async
    func stop()
}

struct RunningApplicationSnapshot: Sendable, Equatable {
    let processID: pid_t
    let bundleIdentifier: String?
    let bundlePath: String?
    let isTerminated: Bool
}

final class XcodeProcessEventMonitor: XcodeProcessEventMonitoring, @unchecked Sendable {
    struct Observation: @unchecked Sendable {
        let cancel: @Sendable () -> Void
    }

    struct Dependencies: @unchecked Sendable {
        let observeRunningApplications:
            @Sendable (
                _ handler: @escaping @Sendable ([RunningApplicationSnapshot]) -> Void
            ) -> Observation
        let targets:
            @Sendable (_ applications: [RunningApplicationSnapshot]) -> [XcodeProcessTarget]

        init(
            observeRunningApplications: @escaping @Sendable (
                _ handler: @escaping @Sendable ([RunningApplicationSnapshot]) -> Void
            ) -> Observation,
            targets: @escaping @Sendable (
                _ applications: [RunningApplicationSnapshot]
            ) -> [XcodeProcessTarget] = XcodeTargetMapper.targets(from:)
        ) {
            self.observeRunningApplications = observeRunningApplications
            self.targets = targets
        }

        #if canImport(AppKit)
        static let live = Self(
            observeRunningApplications: { handler in
                let workspace = NSWorkspace.shared
                let observation = workspace.observe(
                    \.runningApplications,
                    options: [.initial]
                ) { workspace, _ in
                    let applications = workspace.runningApplications
                    handler(applications.map(RunningApplicationSnapshot.init(application:)))
                }
                return Observation {
                    observation.invalidate()
                }
            }
        )
        #endif
    }

    private struct State {
        var isStarted = false
        var isStopped = false
        var lifecycleGeneration: UInt64 = 0
        var observation: Observation?
        var changeHandler: (@Sendable (_ reason: String) -> Void)?
        var targets: [XcodeProcessTarget] = []
        var permissionDialogProcessIDs: [pid_t] = []
        var applicationSnapshotSequence: UInt64 = 0
        var readinessGeneration: UInt64 = 0
        var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var cancelledReadinessWaiterIDs: Set<UUID> = []
    }

    private static let permissionDialogBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.apple.dt.ExternalViewService",
        "com.apple.dt.Xcode.DeveloperSystemPolicyService",
    ]

    private let dependencies: Dependencies
    private let lock = NSLock()
    private var state = State()

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    deinit {
        stop()
    }

    func start() {
        let lifecycleGeneration = lock.withLock { () -> UInt64? in
            guard state.isStarted == false, state.isStopped == false else {
                return nil
            }
            state.isStarted = true
            state.lifecycleGeneration &+= 1
            return state.lifecycleGeneration
        }
        guard let lifecycleGeneration else { return }

        let observation = dependencies.observeRunningApplications { [weak self] applications in
            self?.recordRunningApplications(
                applications,
                lifecycleGeneration: lifecycleGeneration
            )
        }
        let shouldCancel = lock.withLock { () -> Bool in
            guard state.isStarted,
                  state.isStopped == false,
                  state.lifecycleGeneration == lifecycleGeneration
            else {
                return true
            }
            state.observation = observation
            return false
        }
        if shouldCancel {
            observation.cancel()
        }
    }

    func setChangeHandler(
        _ handler: @escaping @Sendable (_ reason: String) -> Void
    ) {
        let shouldInstall = lock.withLock { () -> Bool in
            guard state.isStopped == false else { return false }
            state.changeHandler = handler
            return true
        }
        guard shouldInstall else { return }
        start()
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        lock.withLock { state.targets }
    }

    func permissionDialogProcessIDs() -> [pid_t] {
        lock.withLock { state.permissionDialogProcessIDs }
    }

    func readinessSnapshot() -> UpstreamReadinessSnapshot {
        lock.withLock {
            UpstreamReadinessSnapshot(
                isReady: state.targets.isEmpty == false,
                generation: state.readinessGeneration
            )
        }
    }

    func waitForReadinessChange(after generation: UInt64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    guard state.isStopped == false,
                          state.readinessGeneration == generation,
                          state.cancelledReadinessWaiterIDs.remove(id) == nil,
                          Task.isCancelled == false
                    else {
                        return true
                    }
                    state.readinessWaiters[id] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelReadinessWaiter(id: id)
        }
        _ = lock.withLock {
            state.cancelledReadinessWaiterIDs.remove(id)
        }
    }

    func stop() {
        let stopped = lock.withLock { () -> (
            observation: Observation?,
            waiters: [CheckedContinuation<Void, Never>]
        )? in
            guard state.isStopped == false else { return nil }
            state.isStopped = true
            state.isStarted = false
            state.lifecycleGeneration &+= 1
            let observation = state.observation
            state.observation = nil
            state.changeHandler = nil
            state.targets.removeAll()
            state.permissionDialogProcessIDs.removeAll()
            state.readinessGeneration &+= 1
            let waiters = Array(state.readinessWaiters.values)
            state.readinessWaiters.removeAll()
            state.cancelledReadinessWaiterIDs.removeAll()
            return (observation, waiters)
        }
        guard let stopped else { return }
        stopped.observation?.cancel()
        for waiter in stopped.waiters {
            waiter.resume()
        }
    }

    private func recordRunningApplications(
        _ applications: [RunningApplicationSnapshot],
        lifecycleGeneration: UInt64
    ) {
        let sequence = lock.withLock { () -> UInt64? in
            guard state.isStarted,
                  state.isStopped == false,
                  state.lifecycleGeneration == lifecycleGeneration
            else {
                return nil
            }
            state.applicationSnapshotSequence &+= 1
            return state.applicationSnapshotSequence
        }
        guard let sequence else { return }

        let targets = dependencies.targets(applications)
        let permissionDialogProcessIDs = applications.compactMap { application -> pid_t? in
            guard application.processID > 0,
                  application.isTerminated == false,
                  let bundleIdentifier = application.bundleIdentifier,
                  Self.permissionDialogBundleIdentifiers.contains(bundleIdentifier)
            else {
                return nil
            }
            return application.processID
        }.sorted()

        let update = lock.withLock { () -> (
            changeHandler: (@Sendable (String) -> Void)?,
            waiters: [CheckedContinuation<Void, Never>]
        ) in
            guard state.isStarted,
                  state.isStopped == false,
                  state.lifecycleGeneration == lifecycleGeneration,
                  state.applicationSnapshotSequence == sequence
            else {
                return (nil, [])
            }
            let didChangeTargets = state.targets != targets
            state.targets = targets
            state.permissionDialogProcessIDs = permissionDialogProcessIDs
            guard didChangeTargets else {
                return (nil, [])
            }
            state.readinessGeneration &+= 1
            let waiters = Array(state.readinessWaiters.values)
            state.readinessWaiters.removeAll()
            return (state.changeHandler, waiters)
        }
        for waiter in update.waiters {
            waiter.resume()
        }
        update.changeHandler?("workspace_applications_changed")
    }

    private func cancelReadinessWaiter(id: UUID) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.readinessWaiters.removeValue(forKey: id) else {
                state.cancelledReadinessWaiterIDs.insert(id)
                return nil
            }
            return waiter
        }
        waiter?.resume()
    }
}

#if canImport(AppKit)
private extension RunningApplicationSnapshot {
    init(application: NSRunningApplication) {
        self.init(
            processID: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            bundlePath: application.bundleURL?.path,
            isTerminated: application.isTerminated
        )
    }
}
#endif
