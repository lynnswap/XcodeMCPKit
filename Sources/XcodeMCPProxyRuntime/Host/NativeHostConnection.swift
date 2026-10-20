import Foundation
import Logging
import NIOConcurrencyHelpers
import Synchronization
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

/// Why a host request ended without a host response.
enum NativeHostConnectionError: Error, CustomStringConvertible {
    /// The process could not start, or it ended before responding.
    case unavailable(String)
    /// The process input queue is full.
    case overloaded
    /// The request targets a process that has ended.
    case expired
    case timedOut
    /// The host's reply is not a JSON-RPC response with a result or an error.
    case invalidResponse
    /// The host answered an internal request with a JSON-RPC error response.
    case rejected(response: Data)

    var description: String {
        switch self {
        case .unavailable(let reason): "upstream unavailable: \(reason)"
        case .overloaded: "upstream overloaded"
        case .expired: "This reference belongs to an earlier Xcode connection. Open or list workspaces again, or start a new session."
        case .timedOut: "upstream timeout"
        case .invalidResponse: "invalid upstream response"
        case .rejected(let response): "Native request failed: \(String(decoding: response, as: UTF8.self))"
        }
    }
}

/// Owns the one process of a native host or GUI bridge and multiplexes every MCP session's
/// requests over it. A process start increments `generation`; references created from a
/// process stay valid only while that generation is running.
actor NativeHostConnection {
    struct Status: Sendable {
        enum Phase: String, Sendable { case idle, starting, ready, stopped }
        var phase: Phase = .idle
        /// Generation of the running process, or `nil` when none is running.
        var runningGeneration: UInt64?
        var inFlightRequests = 0
        var origin: JSONValue?
    }

    enum Event: Sendable {
        /// A host notification for `owner`, or for every user of the host when `owner` is `nil`.
        case notification(owner: ProxySessionID?, data: Data)
        case processEnded(generation: UInt64)
    }

    private final class Process: Sendable {
        let generation: UInt64
        let session: any UpstreamSession
        let reader = NIOLockedValueBox<Task<Void, Never>?>(nil)

        init(generation: UInt64, session: any UpstreamSession) {
            self.generation = generation
            self.session = session
        }
    }

    private struct Pending {
        let generation: UInt64
        let owner: ProxySessionID?
        let originalID: JSONValue
        let progress: ProgressTokenMapping?
        var continuation: CheckedContinuation<Data, any Error>?
        var outcome: Result<Data, any Error>?
    }

    private struct Catalog {
        let generation: UInt64
        let epoch: UInt64
        let task: Task<JSONValue, any Error>
    }

    private let factory: any UpstreamSessionFactory
    private let handshake: JSONValue
    private let handshakeTimeout: Duration?
    private let catalogTimeout: Duration?
    private let prewarmsCatalog: Bool
    private let clock: ClockClient
    private let logger: Logger
    private let stderrLimiter = UpstreamStderrLogLimiter()
    private let onEvent: @Sendable (Event) -> Void
    nonisolated let status = NIOLockedValueBox(Status())
    /// The process session that deinitialization cancels, and whether it already did.
    private nonisolated let live = NIOLockedValueBox<(session: (any UpstreamSession)?, cancelled: Bool)>((nil, false))
    /// A requested stop that has not finished; requests wait for it and then start a new process.
    private nonisolated let retirement = NIOLockedValueBox<Task<Void, Never>?>(nil)

    private var generation: UInt64 = 0
    /// The process from launch until it ends; it receives replies even while initializing.
    private var process: Process?
    /// The process once it has completed its handshake; only this one serves requests.
    private var readyProcess: Process?
    private var starting: (generation: UInt64, task: Task<Process, any Error>)?
    private var stopped = false
    private var nextRequestID: Int64 = 0
    private var pending: [Int64: Pending] = [:]
    private var catalog: Catalog?
    private var catalogEpoch: UInt64 = 0
    private var endings: [UInt64: Task<Void, Never>] = [:]

    init(factory: any UpstreamSessionFactory, handshake: JSONValue, handshakeTimeout: Duration?,
         catalogTimeout: Duration?, prewarmsCatalog: Bool, clock: ClockClient, logger: Logger,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.factory = factory
        self.handshake = handshake
        self.handshakeTimeout = handshakeTimeout
        self.catalogTimeout = catalogTimeout
        self.prewarmsCatalog = prewarmsCatalog
        self.clock = clock
        self.logger = logger
        self.onEvent = onEvent
    }

    /// Starts the process unless one is running, and returns its generation.
    @discardableResult
    func start() async throws -> UInt64 { try await runningProcess().generation }

    /// Sends a request object and returns the host's response, which has a result or an error,
    /// with the request's original `id`. Cancelling the caller sends `notifications/cancelled`.
    func send(_ request: JSONValue, owner: ProxySessionID?, generation expected: UInt64?) async throws -> Data {
        let process = try await runningProcess()
        if let expected, process.generation != expected { throw NativeHostConnectionError.expired }
        return try await exchange(request, owner: owner, on: process)
    }

    /// Returns the host's `tools/list` result, loading it once per process and catalog change.
    func nativeCatalog() async throws -> (generation: UInt64, result: JSONValue) {
        while true {
            let process = try await runningProcess()
            let load = catalogLoad(on: process)
            do {
                let result = try await Self.value(of: load.task)
                if load.epoch == catalogEpoch { return (load.generation, result) }
            } catch _ where load.epoch != catalogEpoch && !Task.isCancelled {
                // The load was cancelled or failed after a catalog change superseded it.
            }
        }
    }

    /// Stops the running process. The next request starts a new one.
    func stopProcess() async {
        starting?.task.cancel()
        let pendingStart = starting?.task
        _ = await pendingStart?.result
        if let process {
            let reader = process.reader.withLockedValue { $0 }
            await end(process, reason: "the host was stopped")
            await reader?.value
        }
        await waitForEndings()
    }

    /// Requests a stop of the current process. Once this returns, new requests wait for the stop
    /// and start a new process instead of using the one being stopped.
    @discardableResult
    nonisolated func retire() -> Task<Void, Never> {
        retirement.withLockedValue { pending in
            if let pending { return pending }
            let task = Task {
                await self.stopProcess()
                self.retirement.withLockedValue { $0 = nil }
            }
            pending = task
            return task
        }
    }

    /// Stops the process permanently.
    func shutdown() async {
        stopped = true
        updateStatus { $0.phase = .stopped }
        await stopProcess()
    }

    /// Requests process termination without waiting; used only by deinitialization. A process
    /// that is still starting is cancelled as soon as it exists.
    nonisolated func cancelForDeinit() {
        live.withLockedValue { live in
            live.cancelled = true
            return live.session
        }?.cancel()
    }

    // MARK: - Process lifetime

    private func runningProcess() async throws -> Process {
        while true {
            if let retiring = retirement.withLockedValue({ $0 }) {
                await retiring.value
                continue
            }
            if let readyProcess { return readyProcess }
            guard !stopped, !live.withLockedValue({ $0.cancelled }) else {
                throw NativeHostConnectionError.unavailable("the host has shut down")
            }
            if let starting { return try await Self.value(of: starting.task) }
            // A replacement never runs beside the process it replaces.
            if let ending = endings.values.first {
                await ending.value
                continue
            }
            generation += 1
            let next = generation
            let task = Task { try await launch(generation: next) }
            starting = (next, task)
            updateStatus { $0.phase = .starting }
            return try await Self.value(of: task)
        }
    }

    private func launch(generation: UInt64) async throws -> Process {
        defer { if starting?.generation == generation { starting = nil } }
        let session: any UpstreamSession
        do { session = try await factory.startSession() }
        catch {
            updateStatus { if $0.phase == .starting { $0.phase = .idle } }
            logger.error("Native host process did not start", metadata: ["error": "\(error)"])
            throw NativeHostConnectionError.unavailable(String(describing: error))
        }
        let cancelled = live.withLockedValue { live in
            if !live.cancelled { live.session = session }
            return live.cancelled
        }
        if cancelled {
            session.cancel()
            updateStatus { if $0.phase == .starting { $0.phase = .idle } }
            throw NativeHostConnectionError.unavailable("the host was cancelled while starting")
        }
        let process = Process(generation: generation, session: session)
        self.process = process
        process.reader.withLockedValue { $0 = Task { [weak self] in
            for await event in session.events { await self?.receive(event, from: process) }
            await self?.end(process, reason: "the host process exited")
        } }
        do {
            try Task.checkCancellation()
            let initialize = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .string("initialize"),
                "method": .string("initialize"), "params": handshake,
            ])
            let reply = try await withTimeout(handshakeTimeout) { [self] in
                try await exchange(initialize, owner: nil, on: process)
            }
            guard case .object(let result)? = try? JSONRPC.Wire.resultValue(fromResponseData: reply),
                  case .string(let version)? = result["protocolVersion"] else {
                throw NativeHostConnectionError.unavailable("initialize failed: \(String(decoding: reply, as: UTF8.self))")
            }
            guard MCPProtocolVersion.isSupported(version) else {
                throw NativeHostConnectionError.unavailable("the host negotiated unsupported MCP protocol version \(version)")
            }
            try await write(JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(
                method: "notifications/initialized")), to: process)
            try Task.checkCancellation()
        } catch {
            await end(process, reason: "the host did not initialize: \(error)")
            if error is NativeHostConnectionError { throw error }
            throw NativeHostConnectionError.unavailable(String(describing: error))
        }
        guard self.process === process else { throw NativeHostConnectionError.unavailable("the host process exited") }
        readyProcess = process
        updateStatus {
            $0.phase = .ready
            $0.runningGeneration = generation
        }
        if prewarmsCatalog { _ = catalogLoad(on: process) }
        return process
    }

    /// Fails the process's requests, forgets it, and stops it once. Safe to call repeatedly,
    /// including from the process's own reader, so it never waits for that reader.
    private func end(_ process: Process, reason: String) async {
        if let ending = endings[process.generation] { await ending.value; return }
        guard self.process === process else { return }
        self.process = nil
        if readyProcess === process { readyProcess = nil }
        live.withLockedValue { if $0.session === process.session { $0.session = nil } }
        catalog = nil
        let failed = pending.filter { $0.value.generation == process.generation }
        for id in failed.keys { complete(id, with: .failure(NativeHostConnectionError.unavailable(reason))) }
        updateStatus {
            $0.runningGeneration = nil
            if $0.phase != .stopped { $0.phase = .idle }
        }
        logger.notice("Native host process ended", metadata: ["generation": "\(process.generation)", "reason": "\(reason)"])
        onEvent(.processEnded(generation: process.generation))
        let generation = process.generation
        // The task removes its own entry, so whoever awaits it next sees the process gone.
        let ending = Task {
            await process.session.stop()
            endings[generation] = nil
        }
        endings[generation] = ending
        await ending.value
    }

    private func waitForEndings() async {
        while let ending = endings.values.first { await ending.value }
    }

    // MARK: - Requests

    private func exchange(_ request: JSONValue, owner: ProxySessionID?, on process: Process) async throws -> Data {
        guard case .object(var object) = request, let originalID = object["id"] else {
            throw NativeHostConnectionError.unavailable("invalid host request")
        }
        nextRequestID += 1
        let id = nextRequestID
        object["id"] = .number(.int(id))
        var progress: ProgressTokenMapping?
        if case .object(var parameters)? = object["params"], case .object(var meta)? = parameters["_meta"],
           let token = meta["progressToken"] {
            let upstream = "progress-\(process.generation)-\(id)"
            progress = ProgressTokenMapping(clientToken: token, upstreamToken: upstream)
            meta["progressToken"] = .string(upstream)
            parameters["_meta"] = .object(meta)
            object["params"] = .object(parameters)
        }
        let data = try JSONRPC.Wire.data(from: JSONValue.object(object).foundationObject)
        // A caller cancelled while the process was starting must not reach the host.
        try Task.checkCancellation()
        pending[id] = Pending(generation: process.generation, owner: owner, originalID: originalID, progress: progress)
        refreshInFlightCount()
        do { try await write(data, to: process) }
        catch {
            pending[id] = nil
            refreshInFlightCount()
            throw error
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var entry = pending[id] else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let outcome = entry.outcome {
                    pending[id] = nil
                    continuation.resume(with: outcome)
                } else {
                    entry.continuation = continuation
                    pending[id] = entry
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func write(_ data: Data, to process: Process) async throws {
        switch await process.session.send(data) {
        case .accepted: return
        case .backpressure: throw NativeHostConnectionError.overloaded
        case .unavailable: throw NativeHostConnectionError.unavailable("the host process is not running")
        }
    }

    private func cancel(_ id: Int64) async {
        guard let entry = pending[id], entry.outcome == nil else { return }
        complete(id, with: .failure(CancellationError()))
        guard let process, process.generation == entry.generation else { return }
        let notification = JSONRPC.Wire.notificationObject(method: "notifications/cancelled", params: .object([
            "requestId": .number(.int(id)), "reason": .string("cancelled by the client"),
        ]))
        do { try await write(JSONRPC.Wire.data(from: notification), to: process) }
        catch { logger.debug("Could not deliver a cancellation to the host", metadata: ["error": "\(error)"]) }
    }

    private func complete(_ id: Int64, with outcome: Result<Data, any Error>) {
        guard var entry = pending[id], entry.outcome == nil else { return }
        if let continuation = entry.continuation {
            pending[id] = nil
            continuation.resume(with: outcome)
        } else {
            entry.outcome = outcome
            pending[id] = entry
        }
        refreshInFlightCount()
    }

    private func refreshInFlightCount() {
        let count = pending.values.count { $0.outcome == nil }
        updateStatus { $0.inFlightRequests = count }
    }

    // MARK: - Catalog

    private func catalogLoad(on process: Process) -> Catalog {
        if let catalog, catalog.generation == process.generation, catalog.epoch == catalogEpoch { return catalog }
        let epoch = catalogEpoch
        let generation = process.generation
        let task = Task { [self] in
            do {
                let result = try await withTimeout(catalogTimeout) { [self] in try await loadCatalog(on: process) }
                if case .object(let fields) = result, case .object(let meta)? = fields["_meta"],
                   let origin = meta["com.lynnswap.xcode-mcpkit/origin"] {
                    updateStatus { $0.origin = origin }
                }
                return result
            } catch {
                // A failed load must not be served from the cache to later callers.
                if catalog?.generation == generation, catalog?.epoch == epoch { catalog = nil }
                throw error
            }
        }
        let load = Catalog(generation: generation, epoch: epoch, task: task)
        catalog = load
        return load
    }

    /// Reads every page of the host's `tools/list` into one result without a cursor.
    private func loadCatalog(on process: Process) async throws -> JSONValue {
        var catalog: [String: JSONValue]?
        var tools: [JSONValue] = []
        var cursor: JSONValue?
        var visited: Set<String> = []
        repeat {
            var request: [String: JSONValue] = [
                "jsonrpc": .string("2.0"), "id": .string("tools/list"), "method": .string("tools/list"),
            ]
            if let cursor { request["params"] = .object(["cursor": cursor]) }
            let reply = try await exchange(.object(request), owner: nil, on: process)
            let object = try JSONRPC.Wire.object(fromData: reply)
            if object["error"] != nil { throw NativeHostConnectionError.rejected(response: reply) }
            guard case .object(let page)? = JSONRPC.Wire.resultValue(inResponseObject: object),
                  case .array(let pageTools)? = page["tools"] else {
                throw NativeHostConnectionError.invalidResponse
            }
            if catalog == nil { catalog = page }
            tools += pageTools
            cursor = nil
            switch page["nextCursor"] {
            case .string(let next)?:
                guard visited.insert(next).inserted else { throw NativeHostConnectionError.invalidResponse }
                cursor = .string(next)
            case nil, .null?:
                break
            default:
                throw NativeHostConnectionError.invalidResponse
            }
        } while cursor != nil
        var result = catalog ?? [:]
        result["tools"] = .array(tools)
        result.removeValue(forKey: "nextCursor")
        return .object(result)
    }

    // MARK: - Host messages

    private func receive(_ event: Upstream.Event, from process: Process) async {
        guard self.process === process else { return }
        switch event {
        case .message(let data):
            await receive(message: data, from: process)
        case .stderr(let line):
            log(stderr: line)
            if NativeHostRuntime.isTerminalCoreSimulatorDiagnostic(line) {
                await end(process, reason: "CoreSimulator services became unavailable in the host")
            }
        case .stdoutProtocolViolation(let violation):
            await end(process, reason: "the host violated stdio framing (\(violation.reason.rawValue))")
        case .stdoutClosed, .exit:
            await end(process, reason: "the host process exited")
        case .stdoutBufferSize:
            break
        }
    }

    private func receive(message data: Data, from process: Process) async {
        let object: [String: Any]
        do { object = try JSONRPC.Wire.object(fromData: data) }
        catch {
            await end(process, reason: "the host sent a message that is not a JSON object")
            return
        }
        switch JSONRPC.Message.Inspector.kind(of: object) {
        case .malformed(let id?):
            // A reply to a pending request that is neither a result nor an error.
            if case .number(.int(let key)) = id.value, pending[key]?.generation == process.generation {
                complete(key, with: .failure(NativeHostConnectionError.invalidResponse))
            }
        case .response(let id):
            guard case .number(.int(let key)) = id.value,
                  let entry = pending[key], entry.generation == process.generation else { return }
            var response = object
            response["id"] = entry.originalID.foundationObject
            do { complete(key, with: .success(try JSONRPC.Wire.data(from: response))) }
            catch { complete(key, with: .failure(error)) }
        case .notification("notifications/progress"):
            guard let parameters = object["params"] as? [String: Any],
                  let token = parameters["progressToken"] as? String,
                  let entry = pending.values.first(where: { $0.progress?.upstreamToken == token }),
                  let progress = entry.progress else { return }
            var rewritten = object
            var fields = parameters
            fields["progressToken"] = progress.clientToken.foundationObject
            rewritten["params"] = fields
            if let message = try? JSONRPC.Wire.data(from: rewritten) {
                onEvent(.notification(owner: entry.owner, data: message))
            }
        case .notification("notifications/tools/list_changed"):
            catalogEpoch &+= 1
            // Waiters of the superseded load see the epoch change and load the new catalog.
            catalog?.task.cancel()
            catalog = nil
        case .notification:
            onEvent(.notification(owner: nil, data: data))
        case .request(let method, let id):
            // The handshake advertises no client capabilities; only ping is expected.
            let reply = method == "ping"
                ? JSONRPC.Wire.resultResponseObject(idValue: id.value, result: .object([:]))
                : JSONRPC.Wire.errorResponseObject(id: id, code: -32601, message: "Method not found")
            if let data = try? JSONRPC.Wire.data(from: reply) { try? await write(data, to: process) }
        case .malformed, .other:
            logger.warning("Ignoring an invalid host message")
        }
    }

    private func log(stderr line: String) {
        let decision = stderrLimiter.decision(upstreamIndex: 0, message: line, nowUptimeNs: clock.uptimeNanoseconds())
        guard decision.shouldLog else { return }
        var metadata: Logger.Metadata = [:]
        if decision.suppressedDuplicateCount > 0 {
            metadata["suppressed_duplicates"] = "\(decision.suppressedDuplicateCount)"
        }
        logger.log(level: UpstreamStderrLogFilter.level(for: line), "\(line)", metadata: metadata)
    }

    // MARK: - Support

    private func updateStatus(_ update: (inout Status) -> Void) {
        status.withLockedValue(update)
    }

    /// Waits for a task the connection owns, returning early when the caller is cancelled.
    /// The task keeps running for its other waiters.
    private static func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let waiter = Waiter<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task { waiter.resume(with: await task.result) }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
        }
    }

    private final class Waiter<T: Sendable>: Sendable {
        private let state = Mutex<(continuation: CheckedContinuation<T, any Error>?, result: Result<T, any Error>?)>((nil, nil))

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            let result = state.withLock { state -> Result<T, any Error>? in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }

        func resume(with result: Result<T, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
                guard state.result == nil else { return nil }
                state.result = result
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: result)
        }
    }

    private func withTimeout<T: Sendable>(_ timeout: Duration?, _ operation: @escaping @Sendable () async throws -> T)
        async throws -> T {
        guard let timeout else { return try await operation() }
        let clock = clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                await clock.sleep(timeout)
                try Task.checkCancellation()
                throw NativeHostConnectionError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
