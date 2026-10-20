import Foundation
import Logging
import NIOConcurrencyHelpers
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
    private nonisolated let liveSession = NIOLockedValueBox<(any UpstreamSession)?>(nil)

    private var generation: UInt64 = 0
    private var process: Process?
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
        let process = try await runningProcess()
        let load = catalogLoad(on: process)
        let result = try await load.task.value
        return (load.generation, result)
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

    /// Stops the process permanently.
    func shutdown() async {
        stopped = true
        updateStatus { $0.phase = .stopped }
        await stopProcess()
    }

    /// Requests process termination without waiting; used only by deinitialization.
    nonisolated func cancelForDeinit() { liveSession.withLockedValue { $0 }?.cancel() }

    // MARK: - Process lifetime

    private func runningProcess() async throws -> Process {
        if let process { return process }
        guard !stopped else { throw NativeHostConnectionError.unavailable("the host has shut down") }
        if let starting { return try await starting.task.value }
        generation += 1
        let next = generation
        let task = Task { try await launch(generation: next) }
        starting = (next, task)
        updateStatus { $0.phase = .starting }
        return try await task.value
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
        let process = Process(generation: generation, session: session)
        self.process = process
        liveSession.withLockedValue { $0 = session }
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
            if JSONRPC.Wire.errorPayload(fromResponseData: reply) != nil {
                throw NativeHostConnectionError.unavailable("initialize failed: \(String(decoding: reply, as: UTF8.self))")
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
        liveSession.withLockedValue { if $0 === process.session { $0 = nil } }
        catalog = nil
        let failed = pending.filter { $0.value.generation == process.generation }
        for id in failed.keys { complete(id, with: .failure(NativeHostConnectionError.unavailable(reason))) }
        updateStatus {
            $0.runningGeneration = nil
            if $0.phase != .stopped { $0.phase = .idle }
        }
        logger.notice("Native host process ended", metadata: ["generation": "\(process.generation)", "reason": "\(reason)"])
        onEvent(.processEnded(generation: process.generation))
        let ending = Task { await process.session.stop() }
        endings[process.generation] = ending
        await ending.value
        endings[process.generation] = nil
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
        let request = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("tools/list"), "method": .string("tools/list"),
        ])
        let generation = process.generation
        let task = Task { [self] in
            do {
                let reply = try await withTimeout(catalogTimeout) { [self] in
                    try await exchange(request, owner: nil, on: process)
                }
                let object = try JSONRPC.Wire.object(fromData: reply)
                if object["error"] != nil { throw NativeHostConnectionError.rejected(response: reply) }
                guard let result = JSONRPC.Wire.resultValue(inResponseObject: object) else {
                    throw NativeHostConnectionError.invalidResponse
                }
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
        case .malformed(let id?) where object["method"] == nil:
            // A reply to a pending request without a result or an error.
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
