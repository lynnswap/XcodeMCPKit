import Darwin
import Foundation
import XcodeMCPWire

/// Owns acquisition tasks independently of requests observing their durable state.
@MainActor
final class NativeCrashSyncJobs {
    struct Context: Sendable {
        let id: String
        let directory: URL
        private let jobs: NativeCrashSyncJobs

        fileprivate init(id: String, directory: URL, jobs: NativeCrashSyncJobs) {
            self.id = id
            self.directory = directory
            self.jobs = jobs
        }

        @MainActor func updateProgress(_ fields: [String: JSONValue]) throws {
            try jobs.change(id) { record in
                var progress = record["progress"]?.fields ?? [:]
                progress.merge(fields) { _, new in new }
                record["progress"] = .object(progress)
            }
        }

        @MainActor func setInput(_ input: JSONValue) throws {
            try jobs.change(id) { $0["input"] = input }
        }

        @MainActor func setResult(_ result: JSONValue) throws {
            try jobs.change(id) { $0["result"] = result }
        }
    }

    struct Recovery: Sendable {
        let id: String
        let directory: URL
        let input: JSONValue
        let progress: [String: JSONValue]
        let result: JSONValue
        let state: String
        let errors: [JSONValue]
        let previousJobID: String?
    }

    private let directory: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stopping = false

    init(root: URL) throws {
        directory = root.appending(component: "Jobs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start(input: JSONValue,
               operation: @escaping @MainActor @Sendable (Context) async throws -> JSONValue) throws -> JSONValue {
        try start(input: input, previousJobID: nil, operation: operation)
    }

    func resume(jobID: String,
                operation: @escaping @MainActor @Sendable (Context, Recovery) async throws -> JSONValue) throws -> JSONValue {
        let saved = try recovery(jobID: jobID)
        guard ["interrupted", "failed", "cancelled"].contains(saved.state) else {
            throw NativeRuntimeError.invalidRequest("Only interrupted, failed, or cancelled crash sync jobs can be resumed")
        }
        return try start(input: saved.input, previousJobID: saved.id) { context in
            try await operation(context, saved)
        }
    }

    func recovery(jobID: String) throws -> Recovery {
        _ = try readRecovering(jobID)
        let folder = try location(jobID)
        return try locked(folder) {
            let record = try read(folder)
            guard Self.isTerminal(record["state"]) else {
                throw NativeRuntimeError.invalidRequest("The crash sync job still has an active owner")
            }
            let lease = try openLock(folder.appending(component: "owner.lock"))
            guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                try lease.close()
                if code == EWOULDBLOCK {
                    throw NativeRuntimeError.invalidRequest("The crash sync job still has an active owner")
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            let outcome: Result<Recovery, any Error>
            do {
                guard let input = record["input"], let result = record["result"],
                      case .object(let progress) = record["progress"], case .string(let state) = record["state"] else {
                    throw NativeRuntimeError.unsupportedContract("The saved crash sync job has no recovery input")
                }
                let previousJobID: String?
                if case .string(let previous) = record["previousJobId"] { previousJobID = previous }
                else { previousJobID = nil }
                outcome = .success(Recovery(id: jobID, directory: folder, input: input, progress: progress,
                    result: result, state: state, errors: record["errors"]?.values ?? [], previousJobID: previousJobID))
            } catch { outcome = .failure(error) }
            do { try lease.close() }
            catch {
                if case .failure(let original) = outcome { throw Self.combined(original, error) }
                throw error
            }
            return try outcome.get()
        }
    }

    private func start(input: JSONValue, previousJobID: String?,
                       operation: @escaping @MainActor @Sendable (Context) async throws -> JSONValue) throws -> JSONValue {
        guard !stopping else { throw NativeRuntimeError.unavailable("Crash sync jobs are shutting down") }
        let id = UUID().uuidString
        let folder = try location(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let lease = try openLock(folder.appending(component: "owner.lock"))
        guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = posixError()
            try lease.close()
            throw failure
        }
        let now = Self.now
        let record: [String: JSONValue] = [
            "jobId": .string(id), "previousJobId": previousJobID.map(JSONValue.string) ?? .null,
            "state": .string("queued"), "input": input,
            "progress": .object([:]), "result": .null, "errors": .array([]),
            "createdAt": .string(now), "updatedAt": .string(now),
            "startedAt": .null, "finishedAt": .null, "revision": .number(.int(1)),
        ]
        do { try write(record, to: folder) }
        catch {
            do { try lease.close() }
            catch let cleanup { throw Self.combined(error, cleanup) }
            throw error
        }
        let context = Context(id: id, directory: folder, jobs: self)
        let capture = NativeErrorPresentation.Capture()
        tasks[id] = NativeErrorPresentation.$capture.withValue(capture) {
            NativeExecutionOperations.$scope.withValue(nil) {
                Task { @MainActor [self] in
                    await run(context, lease: lease, capture: capture, operation: operation)
                    tasks[id] = nil
                }
            }
        }
        return Self.publicValue(record)
    }

    func wait(jobID: String, timeout: Double = 1, afterRevision: Int64? = nil) async throws -> JSONValue {
        guard timeout.isFinite, (0...30).contains(timeout) else {
            throw NativeRuntimeError.invalidRequest("wait_seconds must be between 0 and 30")
        }
        if let afterRevision, afterRevision < 0 {
            throw NativeRuntimeError.invalidRequest("after_revision must be nonnegative")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var baseline = afterRevision
        while true {
            try Task.checkCancellation()
            let value = try status(jobID: jobID)
            guard case .number(.int(let revision)) = value.fields?["revision"] else {
                throw NativeRuntimeError.unsupportedContract("Crash sync job has no revision")
            }
            let observed = baseline ?? revision
            baseline = observed
            if Self.isTerminal(value.fields?["state"]) || revision > observed || clock.now >= deadline { return value }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(100))))
        }
    }

    func cancel(jobID: String) throws -> JSONValue {
        let folder = try location(jobID)
        let record = try readRecovering(jobID)
        guard !Self.isTerminal(record["state"]) else { return Self.publicValue(record) }
        try Data().write(to: folder.appending(component: "cancel.request"), options: .atomic)
        try change(jobID) { record in
            if !Self.isTerminal(record["state"]) { record["state"] = .string("cancelling") }
        }
        tasks[jobID]?.cancel()
        return Self.publicValue(try readRecovering(jobID))
    }

    func status(jobID: String) throws -> JSONValue {
        Self.publicValue(try readRecovering(jobID))
    }

    func shutdown() async {
        stopping = true
        let pending = tasks
        for (id, task) in pending {
            do { _ = try cancel(jobID: id) }
            catch { NativeHostDiagnostic.report("Request crash job cancellation: \(error)") }
            task.cancel()
        }
        for task in pending.values { await task.value }
    }

    private func run(_ context: Context, lease: FileHandle, capture: NativeErrorPresentation.Capture,
                     operation: @escaping @MainActor @Sendable (Context) async throws -> JSONValue) async {
        let outcome: Result<JSONValue, any Error>
        do {
            outcome = .success(try await PreviewRendererFileEvents.withEvents(in: context.directory) { events, _ in
                let monitor = Task { @MainActor [self] in
                    for await _ in events {
                        if cancellationRequested(context) {
                            tasks[context.id]?.cancel()
                            return
                        }
                    }
                }
                let operationOutcome: Result<JSONValue, any Error>
                do {
                    if cancellationRequested(context) { tasks[context.id]?.cancel() }
                    try Task.checkCancellation()
                    try change(context.id) { record in
                        if record["state"] == .string("cancelling") { throw CancellationError() }
                        record["state"] = .string("running")
                        record["startedAt"] = .string(Self.now)
                    }
                    operationOutcome = .success(try await operation(context))
                } catch { operationOutcome = .failure(error) }
                monitor.cancel()
                await monitor.value
                let result = try operationOutcome.get()
                try context.setResult(result)
                try Task.checkCancellation()
                return result
            })
        } catch { outcome = .failure(error) }
        let presentationErrors = capture.errors.map { NativeCrashData.diagnostic($0, operation: "nativePresentation") }
        let state: String
        let errors: [JSONValue]
        switch outcome {
        case .success(let result):
            let fields = result.fields ?? [:]
            errors = (fields["errors"]?.values ?? []) + presentationErrors
            let incomplete = fields["cacheInfo"]?.fields?["sourceComplete"] == .bool(false)
            let failed = fields["status"] == .string("failed") || fields["status"] == .string("partial")
                || !errors.isEmpty || incomplete
            state = failed ? "failed" : "completed"
        case .failure(let error):
            state = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            errors = (error is CancellationError ? [] : [NativeCrashData.diagnostic(error, operation: "crashSyncJob")]) + presentationErrors
        }
        do { try finish(context.id, state: state, errors: errors, lease: lease) }
        catch {
            NativeHostDiagnostic.report("Save crash sync job outcome: \(error)")
            do { try lease.close() }
            catch { NativeHostDiagnostic.report("Release crash sync job ownership: \(error)") }
        }
    }

    private func cancellationRequested(_ context: Context) -> Bool {
        FileManager.default.fileExists(atPath: context.directory.appending(component: "cancel.request").path)
    }

    private func finish(_ id: String, state: String, errors: [JSONValue], lease: FileHandle) throws {
        let folder = try location(id)
        // Readers take this lock before probing ownership. Publish the terminal
        // result only after watcher cleanup and lease release, without exposing
        // a lease-free nonterminal record to another host's recovery.
        try locked(folder) {
            var record = try read(folder)
            var combined = record["errors"]?.values ?? []
            for error in (record["result"]?.fields?["errors"]?.values ?? []) + errors where !combined.contains(error) {
                combined.append(error)
            }
            var released = flock(lease.fileDescriptor, LOCK_UN) == 0
            var cleanup: [JSONValue] = []
            if !released {
                cleanup.append(NativeCrashData.diagnostic(posixError(), operation: "crashSyncLeaseUnlock"))
            }
            do { try lease.close(); released = true }
            catch { cleanup.append(NativeCrashData.diagnostic(error, operation: "crashSyncLeaseCleanup")) }
            record["errors"] = .array(combined + cleanup)
            if released {
                record["state"] = .string(cleanup.isEmpty ? state : "failed")
                record["finishedAt"] = .string(Self.now)
            }
            try advance(&record, folder: folder)
        }
    }

    private func readRecovering(_ id: String) throws -> [String: JSONValue] {
        let folder = try location(id)
        return try locked(folder) {
            var record = try read(folder)
            guard !Self.isTerminal(record["state"]) else { return record }
            let lease = try openLock(folder.appending(component: "owner.lock"))
            let acquired = flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0
            let code = errno
            let outcome: Result<[String: JSONValue], any Error>
            do {
                if acquired {
                    record["state"] = .string("interrupted")
                    record["finishedAt"] = .string(Self.now)
                    record["errors"] = .array((record["errors"]?.values ?? []) + [
                        .object(["operation": .string("crashSyncRecovery"),
                                 "message": .string("The crash sync owner ended before saving a terminal result")]),
                    ])
                    try advance(&record, folder: folder)
                } else if code != EWOULDBLOCK {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                outcome = .success(record)
            } catch { outcome = .failure(error) }
            do { try lease.close() }
            catch {
                if case .failure(let original) = outcome { throw Self.combined(original, error) }
                throw error
            }
            return try outcome.get()
        }
    }

    private func change(_ id: String, _ operation: (inout [String: JSONValue]) throws -> Void) throws {
        let folder = try location(id)
        try locked(folder) {
            var record = try read(folder)
            try operation(&record)
            try advance(&record, folder: folder)
        }
    }

    private func advance(_ record: inout [String: JSONValue], folder: URL) throws {
        let revision: Int64
        if case .number(.int(let value)) = record["revision"] { revision = value }
        else { throw NativeRuntimeError.unsupportedContract("Crash sync job has no revision") }
        record["revision"] = .number(.int(revision + 1))
        record["updatedAt"] = .string(Self.now)
        try write(record, to: folder)
    }

    private func location(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else {
            throw NativeRuntimeError.invalidRequest("Unknown crash sync job ID")
        }
        return directory.appending(component: id)
    }

    private func read(_ folder: URL) throws -> [String: JSONValue] {
        try NativeCrashStore.object(Data(contentsOf: folder.appending(component: "job.json")))
    }

    private func write(_ record: [String: JSONValue], to folder: URL) throws {
        let data = try unsafe JSONSerialization.data(withJSONObject: record.mapValues(\.foundationObject), options: [.sortedKeys])
        try data.write(to: folder.appending(component: "job.json"), options: .atomic)
    }

    private func locked<T>(_ folder: URL, operation: () throws -> T) throws -> T {
        let handle = try openLock(folder.appending(component: "state.lock"))
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            let failure = posixError()
            try handle.close()
            throw failure
        }
        let result: T
        do { result = try operation() }
        catch {
            do { try handle.close() }
            catch let cleanup { throw Self.combined(error, cleanup) }
            throw error
        }
        try handle.close()
        return result
    }

    private func openLock(_ url: URL) throws -> FileHandle {
        let descriptor = unsafe open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func combined(_ original: any Error, _ cleanup: any Error) -> NSError {
        NSError(domain: "XcodeMCPKit.CrashSyncJobs", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Crash sync job operation and cleanup failed",
            NSMultipleUnderlyingErrorsKey: [original as NSError, cleanup as NSError],
        ])
    }

    private static func isTerminal(_ value: JSONValue?) -> Bool {
        guard case .string(let state) = value else { return false }
        return ["completed", "failed", "cancelled", "interrupted"].contains(state)
    }

    private static func publicValue(_ record: [String: JSONValue]) -> JSONValue {
        var fields = record
        fields["input"] = nil
        if case .object(var progress) = fields["progress"] {
            // The provider journal is durable recovery input, not status output.
            progress["pages"] = nil
            fields["progress"] = .object(progress)
        }
        return .object(fields)
    }

    private static var now: String { ISO8601DateFormatter().string(from: Date()) }
}

private extension JSONValue {
    var fields: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }
    var values: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}
