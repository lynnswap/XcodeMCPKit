import Foundation
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyTestSupport

@Suite(.serialized)
struct XcodeProcessEventMonitorTests {
    @Test func startCachesTheInitialRunningApplicationSnapshot() throws {
        let fixture = try makeTemporaryXcodeApplication(processID: 101)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let observation = RunningApplicationsObservationFake(initial: [fixture.snapshot])
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }

        monitor.start()

        #expect(observation.observationCount() == 1)
        let targets = monitor.runningXcodeTargets()
        #expect(targets.count == 1)
        #expect(targets.first?.processID == 101)
        #expect(targets.first?.appPath == fixture.appPath)
        #expect(targets.first?.mcpbridgePath == fixture.mcpbridgePath)
        let readiness = monitor.readinessSnapshot()
        #expect(readiness.isReady)
        #expect(readiness.generation == 1)
    }

    @Test func launchAndTerminationReplaceTheTargetCache() throws {
        let fixture = try makeTemporaryXcodeApplication(processID: 202)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let observation = RunningApplicationsObservationFake(initial: [])
        let reasons = LockedReasons()
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }
        monitor.setChangeHandler { reason in
            reasons.append(reason)
        }

        let initialReadiness = monitor.readinessSnapshot()
        #expect(initialReadiness.isReady == false)
        #expect(initialReadiness.generation == 0)

        observation.emit([fixture.snapshot])

        #expect(monitor.runningXcodeTargets().map(\.processID) == [202])
        let launchedReadiness = monitor.readinessSnapshot()
        #expect(launchedReadiness.isReady)
        #expect(launchedReadiness.generation == 1)
        #expect(reasons.values() == ["workspace_applications_changed"])

        observation.emit([
            RunningApplicationSnapshot(
                processID: fixture.snapshot.processID,
                bundleIdentifier: fixture.snapshot.bundleIdentifier,
                bundlePath: fixture.snapshot.bundlePath,
                isTerminated: true
            )
        ])

        #expect(monitor.runningXcodeTargets().isEmpty)
        let terminatedReadiness = monitor.readinessSnapshot()
        #expect(terminatedReadiness.isReady == false)
        #expect(terminatedReadiness.generation == 2)
        #expect(
            reasons.values() == [
                "workspace_applications_changed",
                "workspace_applications_changed",
            ]
        )
    }

    @Test func duplicateSnapshotDoesNotAdvanceGenerationOrWakeReadinessWaiter() async throws {
        let fixture = try makeTemporaryXcodeApplication(processID: 303)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let observation = RunningApplicationsObservationFake(initial: [fixture.snapshot])
        let reasons = LockedReasons()
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }
        monitor.setChangeHandler { reason in
            reasons.append(reason)
        }
        let readiness = monitor.readinessSnapshot()
        let started = AsyncLatch()
        let waiter = Task(priority: .high) {
            await started.open()
            await monitor.waitForReadinessChange(after: readiness.generation)
            return Task.isCancelled
        }
        await started.wait()
        await Task.yield()

        observation.emit([fixture.snapshot])

        #expect(monitor.readinessSnapshot().generation == readiness.generation)
        #expect(reasons.values() == ["workspace_applications_changed"])
        for _ in 0..<8 {
            await Task.yield()
        }
        waiter.cancel()
        let returnedAfterCancellation = try await waitWithTimeout(
            "waiting for duplicate-snapshot readiness waiter cancellation",
            timeout: .seconds(2)
        ) {
            await waiter.value
        }
        #expect(returnedAfterCancellation)
    }

    @Test func permissionDialogProcessIDsIncludeXcodeAndKnownHelpersOnly() {
        let observation = RunningApplicationsObservationFake(initial: [
            RunningApplicationSnapshot(
                processID: 43,
                bundleIdentifier: "com.apple.dt.Xcode.DeveloperSystemPolicyService",
                bundlePath: nil,
                isTerminated: false
            ),
            RunningApplicationSnapshot(
                processID: 41,
                bundleIdentifier: "com.apple.dt.Xcode",
                bundlePath: nil,
                isTerminated: false
            ),
            RunningApplicationSnapshot(
                processID: 42,
                bundleIdentifier: "com.apple.dt.ExternalViewService",
                bundlePath: nil,
                isTerminated: false
            ),
            RunningApplicationSnapshot(
                processID: 44,
                bundleIdentifier: "com.example.Unrelated",
                bundlePath: nil,
                isTerminated: false
            ),
            RunningApplicationSnapshot(
                processID: 45,
                bundleIdentifier: "com.apple.dt.ExternalViewService",
                bundlePath: nil,
                isTerminated: true
            ),
        ])
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }

        monitor.start()

        #expect(monitor.permissionDialogProcessIDs() == [41, 42, 43])
        #expect(monitor.runningXcodeTargets().isEmpty)
    }

    @Test func readinessWaitDoesNotMissAChangeBeforeWaiterRegistration() async throws {
        let fixture = try makeTemporaryXcodeApplication(processID: 404)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let observation = RunningApplicationsObservationFake(initial: [])
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }
        monitor.start()
        let unavailable = monitor.readinessSnapshot()

        observation.emit([fixture.snapshot])

        try await waitWithTimeout(
            "waiting for readiness generation mismatch",
            timeout: .seconds(2)
        ) {
            await monitor.waitForReadinessChange(after: unavailable.generation)
        }
        let available = monitor.readinessSnapshot()
        #expect(available.isReady)
        #expect(available.generation == unavailable.generation + 1)
    }

    @Test func readinessWaitReturnsWhenTheWaitingTaskIsCancelled() async throws {
        let observation = RunningApplicationsObservationFake(initial: [])
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }
        monitor.start()
        let readiness = monitor.readinessSnapshot()
        let started = AsyncLatch()
        let waiter = Task {
            await started.open()
            await monitor.waitForReadinessChange(after: readiness.generation)
        }
        await started.wait()
        await Task.yield()

        waiter.cancel()

        try await waitWithTimeout(
            "waiting for cancelled readiness waiter",
            timeout: .seconds(2)
        ) {
            await waiter.value
        }
        #expect(monitor.readinessSnapshot().generation == readiness.generation)
    }

    @Test func olderConcurrentSnapshotCannotOverwriteNewerSnapshot() async throws {
        let observation = RunningApplicationsObservationFake(initial: [])
        let mapper = BlockingTargetMapper(blockedProcessID: 601)
        let monitor = XcodeProcessEventMonitor(
            dependencies: observation.dependencies(targets: mapper.targets(from:))
        )
        defer {
            mapper.releaseBlockedSnapshot()
            monitor.stop()
        }
        monitor.start()
        let oldSnapshot = RunningApplicationSnapshot(
            processID: 601,
            bundleIdentifier: "com.apple.dt.Xcode",
            bundlePath: "/Applications/Xcode-Old.app",
            isTerminated: false
        )
        let newSnapshot = RunningApplicationSnapshot(
            processID: 602,
            bundleIdentifier: "com.apple.dt.Xcode",
            bundlePath: "/Applications/Xcode-New.app",
            isTerminated: false
        )

        let oldCallback = Task.detached {
            observation.emit([oldSnapshot])
        }
        try await mapper.waitUntilBlocked()
        observation.emit([newSnapshot])
        mapper.releaseBlockedSnapshot()
        await oldCallback.value

        #expect(monitor.runningXcodeTargets().map(\.processID) == [602])
        #expect(monitor.readinessSnapshot().generation == 1)
    }

    @Test func invalidProcessIdentifiersAreIgnored() {
        let observation = RunningApplicationsObservationFake(initial: [
            RunningApplicationSnapshot(
                processID: -1,
                bundleIdentifier: "com.apple.dt.ExternalViewService",
                bundlePath: nil,
                isTerminated: false
            ),
            RunningApplicationSnapshot(
                processID: 0,
                bundleIdentifier: "com.apple.dt.Xcode",
                bundlePath: "/Applications/Xcode.app",
                isTerminated: false
            ),
        ])
        let monitor = makeMonitor(observation: observation)
        defer { monitor.stop() }

        monitor.start()

        #expect(monitor.permissionDialogProcessIDs().isEmpty)
        #expect(monitor.runningXcodeTargets().isEmpty)
        #expect(monitor.readinessSnapshot().isReady == false)
    }

    @Test func stopCancelsObservationAndIgnoresLateCallbacks() throws {
        let fixture = try makeTemporaryXcodeApplication(processID: 505)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let observation = RunningApplicationsObservationFake(initial: [])
        let reasons = LockedReasons()
        let monitor = makeMonitor(observation: observation)
        monitor.setChangeHandler { reason in
            reasons.append(reason)
        }

        monitor.stop()
        let stoppedReadiness = monitor.readinessSnapshot()
        observation.emit([
            fixture.snapshot,
            RunningApplicationSnapshot(
                processID: 506,
                bundleIdentifier: "com.apple.dt.ExternalViewService",
                bundlePath: nil,
                isTerminated: false
            ),
        ])
        monitor.start()

        #expect(observation.cancellationCount() == 1)
        #expect(observation.observationCount() == 1)
        #expect(monitor.runningXcodeTargets().isEmpty)
        #expect(monitor.permissionDialogProcessIDs().isEmpty)
        let readinessAfterLateCallback = monitor.readinessSnapshot()
        #expect(readinessAfterLateCallback.isReady == false)
        #expect(readinessAfterLateCallback.generation == stoppedReadiness.generation)
        #expect(reasons.values().isEmpty)
    }
}

private func makeMonitor(
    observation: RunningApplicationsObservationFake
) -> XcodeProcessEventMonitor {
    XcodeProcessEventMonitor(dependencies: observation.dependencies())
}

private struct TemporaryXcodeApplicationFixture {
    let rootURL: URL
    let appPath: String
    let mcpbridgePath: String
    let snapshot: RunningApplicationSnapshot
}

private enum TemporaryXcodeApplicationFixtureError: Error {
    case couldNotCreateMCPBridge
}

private func makeTemporaryXcodeApplication(
    processID: pid_t
) throws -> TemporaryXcodeApplicationFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = rootURL.appendingPathComponent("Xcode.app", isDirectory: true)
    let mcpbridgeURL = appURL
        .appendingPathComponent("Contents/Developer/usr/bin", isDirectory: true)
        .appendingPathComponent("mcpbridge", isDirectory: false)
    try FileManager.default.createDirectory(
        at: mcpbridgeURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard FileManager.default.createFile(
        atPath: mcpbridgeURL.path,
        contents: Data("#!/bin/sh\n".utf8),
        attributes: [.posixPermissions: 0o755]
    ) else {
        throw TemporaryXcodeApplicationFixtureError.couldNotCreateMCPBridge
    }
    return TemporaryXcodeApplicationFixture(
        rootURL: rootURL,
        appPath: appURL.path,
        mcpbridgePath: mcpbridgeURL.path,
        snapshot: RunningApplicationSnapshot(
            processID: processID,
            bundleIdentifier: "com.apple.dt.Xcode",
            bundlePath: appURL.path,
            isTerminated: false
        )
    )
}

private final class RunningApplicationsObservationFake: @unchecked Sendable {
    private struct State {
        let initial: [RunningApplicationSnapshot]
        var handler: (@Sendable ([RunningApplicationSnapshot]) -> Void)?
        var observationCount = 0
        var cancellationCount = 0
    }

    private let lock = NSLock()
    private var state: State

    init(initial: [RunningApplicationSnapshot]) {
        state = State(initial: initial)
    }

    func dependencies(
        targets: @escaping @Sendable ([RunningApplicationSnapshot]) -> [XcodeProcessTarget]
            = XcodeTargetMapper.targets(from:)
    ) -> XcodeProcessEventMonitor.Dependencies {
        XcodeProcessEventMonitor.Dependencies(
            observeRunningApplications: { [self] handler in
                let initial = lock.withLock {
                    state.observationCount += 1
                    state.handler = handler
                    return state.initial
                }
                handler(initial)
                return XcodeProcessEventMonitor.Observation { [self] in
                    lock.withLock {
                        state.cancellationCount += 1
                    }
                }
            },
            targets: targets
        )
    }

    func emit(_ applications: [RunningApplicationSnapshot]) {
        let handler = lock.withLock { state.handler }
        handler?(applications)
    }

    func observationCount() -> Int {
        lock.withLock { state.observationCount }
    }

    func cancellationCount() -> Int {
        lock.withLock { state.cancellationCount }
    }
}

private final class BlockingTargetMapper: @unchecked Sendable {
    private let blockedProcessID: pid_t
    private let blocked = TestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didRelease = false

    init(blockedProcessID: pid_t) {
        self.blockedProcessID = blockedProcessID
    }

    func targets(from applications: [RunningApplicationSnapshot]) -> [XcodeProcessTarget] {
        if applications.contains(where: { $0.processID == blockedProcessID }) {
            blocked.signal()
            releaseSemaphore.wait()
        }
        return applications.map { application in
            let appPath = application.bundlePath ?? "/Applications/Xcode.app"
            return XcodeProcessTarget(
                processID: application.processID,
                appPath: appPath,
                developerDir: "\(appPath)/Contents/Developer",
                mcpbridgePath: "\(appPath)/Contents/Developer/usr/bin/mcpbridge",
                xcodeVersion: "27.0"
            )
        }
    }

    func waitUntilBlocked() async throws {
        try await blocked.wait(description: "waiting for old target mapping to block")
    }

    func releaseBlockedSnapshot() {
        let shouldRelease = lock.withLock { () -> Bool in
            guard didRelease == false else { return false }
            didRelease = true
            return true
        }
        if shouldRelease {
            releaseSemaphore.signal()
        }
    }
}

private final class LockedReasons: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }

    func values() -> [String] {
        lock.withLock { storage }
    }
}

private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
