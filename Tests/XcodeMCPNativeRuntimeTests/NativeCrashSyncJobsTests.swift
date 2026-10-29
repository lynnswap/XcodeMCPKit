import Darwin
import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeCrashSyncJobsTests {
    @Test func aWaiterCannotCancelAcquisitionAndAnotherOwnerCanReadItsState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try NativeCrashSyncJobs(root: root)
        let observer = try NativeCrashSyncJobs(root: root)
        let started = Latch()
        let release = Latch()
        let finish = Latch()
        let waiterStarted = Latch()
        let waiterState = Probe()
        let scope = NativeExecutionOperations.Scope()
        let requestCapture = NativeErrorPresentation.Capture()
        let initial = try NativeErrorPresentation.$capture.withValue(requestCapture) {
            try NativeExecutionOperations.$scope.withValue(scope) {
                try jobs.start(input: .object(["original": .bool(true)])) { context in
                    #expect(NativeExecutionOperations.scope == nil)
                    #expect(NativeErrorPresentation.capture != nil)
                    #expect(NativeErrorPresentation.capture !== requestCapture)
                    try context.setInput(.object(["resolved": .bool(true)]))
                    try context.updateProgress(["capturedPages": .number(.int(1)), "pages": .array([.string("saved-page")])])
                    started.signal()
                    await release.wait()
                    try context.updateProgress(["capturedPages": .number(.int(2))])
                    await finish.wait()
                    return complete
                }
            }
        }
        let id = try identifier(initial)
        #expect(try fields(initial)["state"] == .string("queued"))
        await started.wait()
        let baseline = try revision(observer.status(jobID: id))
        let waiter = Task {
            waiterStarted.signal()
            let result = try await jobs.wait(jobID: id, timeout: 30, afterRevision: baseline)
            waiterState.finished = true
            return result
        }
        await waiterStarted.wait()
        #expect(!waiterState.finished)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        let running = try observer.status(jobID: id)
        #expect(try fields(running)["state"] == .string("running"))
        #expect(try fields(running)["input"] == nil)
        #expect(try fields(running)["progress"] == .object(["capturedPages": .number(.int(1))]))
        release.signal()
        let progress = try await observer.wait(jobID: id, timeout: 5, afterRevision: baseline)
        #expect(try fields(progress)["state"] == .string("running"))
        #expect(try fields(progress)["progress"] == .object(["capturedPages": .number(.int(2))]))
        // The caller may receive the update before starting its next wait.
        #expect(try revision(observer.status(jobID: id)) > baseline)
        let replayed = try await observer.wait(jobID: id, timeout: 5, afterRevision: baseline)
        #expect(try revision(replayed) == revision(progress))
        finish.signal()
        let finished = try await terminal(observer, id: id)
        #expect(try fields(finished)["state"] == .string("completed"))
        #expect(try fields(finished)["result"] == complete)
        #expect(requestCapture.errors.isEmpty)
        let lease = try FileHandle(forUpdating: root.appending(path: "Jobs/\(id)/owner.lock"))
        #expect(flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
        try lease.close()
        let saved = try NativeCrashStore.object(Data(contentsOf: root.appending(path: "Jobs/\(id)/job.json")))
        #expect(saved["input"] == .object(["resolved": .bool(true)]))
        #expect(try fields(try #require(saved["progress"]))["pages"] == .array([.string("saved-page")]))
        await jobs.shutdown()
    }

    @Test func cancellationBeforeWatcherRegistrationDoesNotStartTheOperation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try NativeCrashSyncJobs(root: root)
        let other = try NativeCrashSyncJobs(root: root)
        let state = Probe()
        let id = try identifier(jobs.start(input: .null) { _ in
            state.started = true
            return complete
        })
        #expect(try fields(other.cancel(jobID: id))["state"] == .string("cancelling"))
        let finished = try await terminal(other, id: id)
        #expect(try fields(finished)["state"] == .string("cancelled"))
        #expect(!state.started)
        await jobs.shutdown()
    }

    @Test func crossOwnerCancellationWaitsForCleanupAndPreservesPartialResult() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try NativeCrashSyncJobs(root: root)
        let other = try NativeCrashSyncJobs(root: root)
        let started = Latch()
        let cleanupStarted = Latch()
        let cleanupMayFinish = Latch()
        let partial: JSONValue = .object(["status": .string("partial"), "savedPages": .number(.int(3))])
        let id = try identifier(jobs.start(input: .null) { context in
            started.signal()
            do {
                try await Task.sleep(for: .seconds(60))
                return complete
            } catch {
                try context.setResult(partial)
                cleanupStarted.signal()
                await cleanupMayFinish.wait()
                throw error
            }
        })
        await started.wait()
        #expect(try fields(other.cancel(jobID: id))["state"] == .string("cancelling"))
        await cleanupStarted.wait()
        #expect(try fields(other.status(jobID: id))["state"] == .string("cancelling"))
        cleanupMayFinish.signal()
        let finished = try await terminal(other, id: id)
        #expect(try fields(finished)["state"] == .string("cancelled"))
        #expect(try fields(finished)["result"] == partial)
        await jobs.shutdown()
    }

    @Test func shutdownJoinsCleanupAndRejectsNewAcquisitions() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try NativeCrashSyncJobs(root: root)
        let started = Latch()
        let cleanupStarted = Latch()
        let cleanupMayFinish = Latch()
        let probe = Probe()
        let id = try identifier(jobs.start(input: .null) { _ in
            started.signal()
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                cleanupStarted.signal()
                await cleanupMayFinish.wait()
                throw error
            }
            return complete
        })
        await started.wait()
        let shutdown = Task { await jobs.shutdown(); probe.finished = true }
        await cleanupStarted.wait()
        #expect(!probe.finished)
        #expect(throws: (any Error).self) { try jobs.start(input: .null) { _ in complete } }
        cleanupMayFinish.signal()
        await shutdown.value
        #expect(probe.finished)
        #expect(try fields(jobs.status(jobID: id))["state"] == .string("cancelled"))
    }

    @Test func providerFailureRetainsBothPartialDataAndItsCause() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try NativeCrashSyncJobs(root: root)
        let partial: JSONValue = .object(["savedPages": .number(.int(2))])
        let id = try identifier(jobs.start(input: .null) { context in
            try context.setResult(partial)
            NativeErrorPresentation.report(NSError(domain: "SuppressedCleanupFailure", code: 23))
            throw NSError(domain: "AcquisitionFailure", code: 17)
        })
        let result = try fields(await terminal(jobs, id: id))
        #expect(result["state"] == .string("failed"))
        #expect(result["result"] == partial)
        guard case .array(let errors) = result["errors"] else { throw FixtureError.notAnObject }
        #expect(try errors.contains { try fields($0)["domain"] == .string("AcquisitionFailure") })
        #expect(try errors.contains { try fields($0)["domain"] == .string("SuppressedCleanupFailure") })
        await jobs.shutdown()
    }

    @Test func anAbandonedOwnerIsInterruptedWithoutDiscardingSavedData() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try NativeCrashSyncJobs(root: root)
        let partial: JSONValue = .object(["status": .string("partial"), "nextCursor": .string("saved-import")])
        let id = try identifier(jobs.start(input: .object(["bundle": .string("example.App")])) { context in
            try context.updateProgress(["capturedPages": .number(.int(2))])
            return partial
        })
        #expect(try fields(await terminal(jobs, id: id))["state"] == .string("failed"))
        await jobs.shutdown()
        let path = root.appending(path: "Jobs/\(id)/job.json")
        var saved = try NativeCrashStore.object(Data(contentsOf: path))
        saved["state"] = .string("running")
        let data = try unsafe JSONSerialization.data(withJSONObject: saved.mapValues(\.foundationObject))
        try data.write(to: path, options: .atomic)
        let restored = try NativeCrashSyncJobs(root: root)
        let interrupted = try fields(restored.status(jobID: id))
        #expect(interrupted["state"] == .string("interrupted"))
        #expect(interrupted["result"] == partial)
        #expect(interrupted["progress"] == .object(["capturedPages": .number(.int(2))]))
        #expect(try NativeCrashStore.object(Data(contentsOf: path))["state"] == .string("interrupted"))
        #expect(throws: (any Error).self) { try restored.status(jobID: "../outside") }
        await restored.shutdown()
    }

    private var complete: JSONValue { .object(["status": .string("complete"), "errors": .array([])]) }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fields(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let fields) = value else { throw FixtureError.notAnObject }
        return fields
    }

    private func identifier(_ value: JSONValue) throws -> String {
        guard case .string(let id) = try fields(value)["jobId"] else { throw FixtureError.notAnObject }
        return id
    }

    private func revision(_ value: JSONValue) throws -> Int64 {
        guard case .number(.int(let revision)) = try fields(value)["revision"] else { throw FixtureError.notAnObject }
        return revision
    }

    private func terminal(_ jobs: NativeCrashSyncJobs, id: String) async throws -> JSONValue {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var result = try jobs.status(jobID: id)
        while clock.now < deadline {
            let state = try fields(result)["state"]
            if let state, ["completed", "failed", "cancelled", "interrupted"].map(JSONValue.string).contains(state) { return result }
            result = try await jobs.wait(jobID: id, timeout: 1, afterRevision: revision(result))
        }
        throw FixtureError.notTerminal
    }

    private enum FixtureError: Error { case notAnObject, notTerminal }

    @MainActor private final class Probe {
        var started = false
        var finished = false
    }

    @MainActor private final class Latch {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func signal() {
            open = true
            let pending = waiting
            waiting.removeAll()
            for continuation in pending { continuation.resume() }
        }

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}
