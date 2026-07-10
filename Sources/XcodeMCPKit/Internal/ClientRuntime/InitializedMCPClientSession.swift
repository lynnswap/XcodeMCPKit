import Foundation
import Synchronization

private enum MCPClientTaskContext {
    struct ProgressTaskIdentity: Equatable, Sendable {
        let laneID: UUID
        let taskID: UUID
    }

    @TaskLocal static var progressTaskIdentity: ProgressTaskIdentity?
}

private final class MCPProgressLane: Sendable {
    private struct State {
        var accepting = true
        var tail: Task<Void, Never>?
        var tasks: [UUID: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    private let id = UUID()

    func submit(
        _ value: JSONValue,
        to handler: @escaping @Sendable (JSONValue) async -> Void
    ) {
        state.withLock { state in
            guard state.accepting else { return }
            let previous = state.tail
            let id = UUID()
            let identity = MCPClientTaskContext.ProgressTaskIdentity(
                laneID: self.id,
                taskID: id
            )
            let task = Task {
                await MCPClientTaskContext.$progressTaskIdentity.withValue(identity) {
                    if let previous { await previous.value }
                    guard Task.isCancelled == false else { return }
                    await handler(value)
                }
            }
            state.tasks[id] = task
            state.tail = task
        }
    }

    func closeAdmission() {
        state.withLock { $0.accepting = false }
    }

    func closeAndDrain(cancel: Bool = false) async -> [Task<Void, Never>] {
        let currentIdentity = MCPClientTaskContext.progressTaskIdentity
        let tasks = state.withLock { state in
            state.accepting = false
            let tasks = state.tasks
            state.tail = nil
            return tasks
        }
        if currentIdentity?.laneID == id {
            if cancel {
                for (id, task) in tasks where id != currentIdentity?.taskID { task.cancel() }
            }
            // The current callback is waiting for this close call, and every
            // successor waits for the current callback. Their completion is
            // therefore outside this reentrant close stack. Successors are
            // cancelled above and the current callback returns immediately
            // after close completes its resource teardown.
            return Array(tasks.values)
        }
        if cancel {
            for task in tasks.values { task.cancel() }
        }
        for task in tasks.values { await task.value }
        state.withLock { state in
            for id in tasks.keys {
                state.tasks.removeValue(forKey: id)
            }
        }
        return []
    }

    func cancel() {
        let tasks = state.withLock { state in
            state.accepting = false
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
    }
}

private final class MCPClientSendTaskOwner: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var isActivated = false
        var isCancelled = false
        var activationWaiters: [CheckedContinuation<Void, Never>] = []
        var installationWaiters: [CheckedContinuation<Task<Void, Never>, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ task: Task<Void, Never>) {
        let result = state.withLock { state in
            precondition(state.task == nil)
            state.task = task
            state.isActivated = true
            let activationWaiters = state.activationWaiters
            let installationWaiters = state.installationWaiters
            state.activationWaiters.removeAll()
            state.installationWaiters.removeAll()
            return (state.isCancelled, activationWaiters, installationWaiters)
        }
        if result.0 { task.cancel() }
        for waiter in result.1 { waiter.resume() }
        for waiter in result.2 { waiter.resume(returning: task) }
    }

    func waitUntilActivated() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.isActivated == false else { return true }
                state.activationWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }

    func waitForCompletion() async {
        let task = await withCheckedContinuation { continuation in
            let installedTask = state.withLock { state -> Task<Void, Never>? in
                guard let task = state.task else {
                    state.installationWaiters.append(continuation)
                    return nil
                }
                return task
            }
            if let installedTask { continuation.resume(returning: installedTask) }
        }
        await task.value
    }

    deinit {
        cancel()
    }
}

private final class MCPClientPendingRequests: Sendable {
    struct PendingRequest {
        let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
        let progressLane: MCPProgressLane?
        let sendTaskOwner: MCPClientSendTaskOwner
    }

    private struct State {
        var requests: [String: PendingRequest] = [:]
        var drainingSendTasks: [String: MCPClientSendTaskOwner] = [:]
    }

    private let state = Mutex(State())

    func add(
        idKey: String,
        continuation: AsyncThrowingStream<JSONValue, Error>.Continuation,
        progressLane: MCPProgressLane?,
        sendTaskOwner: MCPClientSendTaskOwner
    ) {
        state.withLock {
            precondition($0.requests[idKey] == nil)
            $0.requests[idKey] = PendingRequest(
                continuation: continuation,
                progressLane: progressLane,
                sendTaskOwner: sendTaskOwner
            )
        }
    }

    func take(idKey: String) -> PendingRequest? {
        state.withLock { state in
            guard let request = state.requests.removeValue(forKey: idKey) else { return nil }
            state.drainingSendTasks[idKey] = request.sendTaskOwner
            return request
        }
    }

    func fail(idKey: String, error: any Error) {
        let request = take(idKey: idKey)
        request?.progressLane?.closeAdmission()
        request?.sendTaskOwner.cancel()
        request?.continuation.finish(throwing: error)
    }

    func failAll(error: any Error) {
        let pending = state.withLock { state in
            let current = state.requests
            state.requests.removeAll()
            for (idKey, request) in current {
                state.drainingSendTasks[idKey] = request.sendTaskOwner
            }
            return current
        }
        for request in pending.values {
            request.progressLane?.closeAdmission()
            request.sendTaskOwner.cancel()
            request.continuation.finish(throwing: error)
        }
    }

    func drainSendTask(idKey: String) async {
        guard let owner = state.withLock({ $0.drainingSendTasks[idKey] }) else { return }
        await owner.waitForCompletion()
        state.withLock { state in
            if state.drainingSendTasks[idKey] === owner {
                state.drainingSendTasks.removeValue(forKey: idKey)
            }
        }
    }

    func drainAllSendTasks() async {
        while true {
            let owners = state.withLock { Array($0.drainingSendTasks.values) }
            guard owners.isEmpty == false else { return }
            for owner in owners { await owner.waitForCompletion() }
            state.withLock { state in
                for owner in owners {
                    state.drainingSendTasks = state.drainingSendTasks.filter { $0.value !== owner }
                }
            }
        }
    }
}

package actor InitializedMCPClientSession {
    package struct Configuration: Sendable {
        package var clientName: String
        package var clientVersion: String
        package var capabilities: [String: JSONValue]
        package var requestTimeout: Duration?
        package var clock: ClockClient

        package init(
            clientName: String,
            clientVersion: String,
            capabilities: [String: JSONValue],
            requestTimeout: Duration?,
            clock: ClockClient = .liveValue
        ) {
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
            self.requestTimeout = requestTimeout
            self.clock = clock
        }
    }

    package typealias ProgressHandler = @Sendable (JSONValue) async -> Void

    private let configuration: Configuration
    private let authority: MCPClientSessionAuthority
    private let pendingRequests = MCPClientPendingRequests()
    private var nextRequestID: Int64 = 1
    private var isClosed = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeCompletionTask: Task<Void, Never>?
    private var deferredProgressTasks: [Task<Void, Never>] = []
    private var eventTask: Task<Void, Never>?
    private var progressHandlers: [String: ProgressHandler] = [:]
    private var progressLanes: [String: MCPProgressLane] = [:]

    package init(authority: MCPClientSessionAuthority, configuration: Configuration) {
        self.configuration = configuration
        self.authority = authority
        self.eventTask = nil
    }

    package static func start(
        transport: any XcodeMCPTransport,
        configuration: Configuration
    ) async throws -> InitializedMCPClientSession {
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { transport },
            initialize: MCPManagedInitializeContext(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion,
                capabilities: configuration.capabilities
            ),
            defaultTimeout: configuration.requestTimeout,
            clock: configuration.clock
        )
        let session = InitializedMCPClientSession(
            authority: authority,
            configuration: configuration
        )
        await session.start()
        return session
    }

    package func start() {
        precondition(eventTask == nil)
        let events = authority.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard Task.isCancelled == false else { return }
                await self?.handle(event)
            }
        }
    }

    package func request(
        _ method: String,
        params: JSONValue? = nil,
        deadline: Deadline?,
        replayPolicy: MCPReplayPolicy = .onceWhenRejectedBeforeProcessing,
        onProgress: ProgressHandler? = nil
    ) async throws -> JSONValue {
        guard method.isEmpty == false else {
            throw MCPBridgeRuntimeError.invalidRequest("method must not be empty")
        }
        try ensureOpen()

        let requestID = nextRequestID
        nextRequestID += 1
        let id = JSONRPC.ID(any: NSNumber(value: requestID))!
        let idKey = id.key

        let progressToken: String?
        let lane: MCPProgressLane?
        let requestParams: JSONValue?
        if let onProgress {
            let token = "xcode-mcp-\(UUID().uuidString)"
            let progressLane = MCPProgressLane()
            progressToken = token
            lane = progressLane
            requestParams = try paramsByAddingProgressToken(token, to: params)
            progressHandlers[token] = onProgress
            progressLanes[token] = progressLane
        } else {
            progressToken = nil
            lane = nil
            requestParams = params
        }

        defer {
            if let progressToken {
                progressHandlers.removeValue(forKey: progressToken)
                progressLanes.removeValue(forKey: progressToken)
            }
        }

        let payload = try makeJSONRPCPayload(id: id, method: method, params: requestParams)
        let requestDeadline = deadline
        if requestDeadline?.hasExpired == true {
            throw MCPBridgeRuntimeError.requestTimedOut(method: method)
        }
        let operation = MCPClientOperation(
            envelope: try MCPClientEnvelope(data: payload),
            deadline: requestDeadline,
            replayPolicy: replayPolicy
        )
        let sessionAuthority = authority
        let pendingRegistry = pendingRequests
        let sendTaskOwner = MCPClientSendTaskOwner()
        let resultPair = AsyncThrowingStream.makeStream(
            of: JSONValue.self,
            throwing: Error.self
        )
        pendingRegistry.add(
            idKey: idKey,
            continuation: resultPair.continuation,
            progressLane: lane,
            sendTaskOwner: sendTaskOwner
        )
        let sendTask = Task { [sessionAuthority] in
            await sendTaskOwner.waitUntilActivated()
            do {
                try Task.checkCancellation()
                try await sessionAuthority.send(operation)
            } catch {
                pendingRegistry.fail(
                    idKey: idKey,
                    error: Self.runtimeError(from: error)
                )
            }
        }
        sendTaskOwner.install(sendTask)

        do {
            let resultStream = resultPair.stream
            let result = try await withRequestDeadline(
                requestDeadline,
                method: method
            ) {
                try await withTaskCancellationHandler {
                    var iterator = resultStream.makeAsyncIterator()
                    guard let result = try await iterator.next() else {
                        try Task.checkCancellation()
                        throw MCPBridgeRuntimeError.closed
                    }
                    return result
                } onCancel: {
                    pendingRegistry.fail(idKey: idKey, error: CancellationError())
                    lane?.cancel()
                }
            }
            await pendingRegistry.drainSendTask(idKey: idKey)
            if isClosed == false {
                _ = await lane?.closeAndDrain()
            }
            return result
        } catch {
            pendingRegistry.fail(idKey: idKey, error: error)
            await pendingRegistry.drainSendTask(idKey: idKey)
            if isClosed == false {
                _ = await lane?.closeAndDrain(cancel: true)
            }
            if method != "initialize", Self.requiresCancellationNotification(error) {
                await sendCancellationNotification(for: id)
            }
            throw error
        }
    }

    package func reconnect(deadline: Deadline?) async throws {
        try ensureOpen()
        try await authority.reconnect(deadline: deadline)
    }

    package func connectionState() async -> XcodeMCPConnectionSnapshot {
        await authority.connectionState()
    }

    package func connectionStates() async -> AsyncStream<XcodeMCPConnectionSnapshot> {
        await authority.connectionStates()
    }

    package func close() async {
        guard isClosed == false else {
            guard closeCompleted == false else { return }
            if let closeCompletionTask {
                await closeCompletionTask.value
                return
            }
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        isClosed = true
        let lanes = Array(progressLanes.values)
        progressHandlers.removeAll()
        progressLanes.removeAll()
        pendingRequests.failAll(error: MCPBridgeRuntimeError.closed)
        await pendingRequests.drainAllSendTasks()
        var deferredProgressTasks: [Task<Void, Never>] = []
        for lane in lanes {
            deferredProgressTasks += await lane.closeAndDrain(cancel: true)
        }
        await authority.close()
        eventTask?.cancel()
        let task = eventTask
        eventTask = nil
        await task?.value
        guard deferredProgressTasks.isEmpty == false else {
            finishClose()
            return
        }
        self.deferredProgressTasks = deferredProgressTasks
        closeCompletionTask = Task { [weak self, deferredProgressTasks] in
            for task in deferredProgressTasks { await task.value }
            await self?.finishClose()
        }
    }

    func finishClose() {
        guard closeCompleted == false else { return }
        closeCompleted = true
        closeCompletionTask = nil
        deferredProgressTasks.removeAll()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    isolated deinit {
        eventTask?.cancel()
        for lane in progressLanes.values { lane.cancel() }
        pendingRequests.failAll(error: MCPBridgeRuntimeError.closed)
        closeCompletionTask?.cancel()
        for task in deferredProgressTasks { task.cancel() }
        for waiter in closeWaiters { waiter.resume() }
    }
}

private extension InitializedMCPClientSession {
    static func runtimeError(from error: any Error) -> any Error {
        if let error = error as? MCPBridgeRuntimeError { return error }
        if let error = error as? MCPClientSessionFailure { return error }
        if let failure = error as? MCPTransportFailure {
            switch failure {
            case .sessionExpired(let sessionID, _):
                return MCPBridgeRuntimeError.transportUnavailable(
                    "Streamable HTTP session expired: \(sessionID)"
                )
            case .deliveryUnknown(let reason), .unavailable(let reason):
                return MCPBridgeRuntimeError.transportUnavailable(reason)
            }
        }
        if error is CancellationError { return error }
        return MCPBridgeRuntimeError.transportUnavailable(errorDescription(error))
    }

    static func errorDescription(_ error: any Error) -> String {
        let nsError = error as NSError
        return nsError.localizedDescription.isEmpty
            ? String(describing: error)
            : nsError.localizedDescription
    }

    static func requiresCancellationNotification(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let runtimeError = error as? MCPBridgeRuntimeError else { return false }
        if case .requestTimedOut = runtimeError { return true }
        return false
    }

    func withRequestDeadline<T: Sendable>(
        _ deadline: Deadline?,
        method: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let deadline else { return try await operation() }
        guard deadline.hasExpired == false else {
            throw MCPBridgeRuntimeError.requestTimedOut(method: method)
        }
        let clock = configuration.clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                await clock.sleep(deadline.remainingDuration())
                try Task.checkCancellation()
                throw MCPBridgeRuntimeError.requestTimedOut(method: method)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func ensureOpen() throws {
        if isClosed { throw MCPBridgeRuntimeError.closed }
    }

    func handle(_ event: MCPClientSessionEvent) async {
        switch event {
        case .message(_, let envelope):
            await handleMessage(envelope)
        case .connectionState(let snapshot):
            if case .closed = snapshot.phase {
                pendingRequests.failAll(error: MCPBridgeRuntimeError.closed)
            } else if case .unavailable(let failure) = snapshot.phase {
                switch failure {
                case .transportUnavailable(let reason):
                    pendingRequests.failAll(
                        error: MCPBridgeRuntimeError.transportUnavailable(reason)
                    )
                case .sessionRecoveryFailed(let reason):
                    pendingRequests.failAll(
                        error: MCPClientSessionFailure.sessionRecoveryFailed(reason)
                    )
                case .protocolViolation(let reason):
                    pendingRequests.failAll(error: MCPBridgeRuntimeError.invalidResponse(reason))
                }
            }
        }
    }

    func handleMessage(_ envelope: MCPClientEnvelope) async {
        do {
            let object = try parseJSONObject(envelope.data)
            if let id = object["id"], let idKey = jsonRPCIDKey(id) {
                if object["method"]?.stringValue != nil {
                    try await respondToUnsupportedServerRequest(id: id)
                    return
                }
                guard let pending = pendingRequests.take(idKey: idKey) else { return }
                pending.progressLane?.closeAdmission()
                pending.sendTaskOwner.cancel()
                if let errorValue = object["error"] {
                    pending.continuation.finish(throwing: parseServerError(errorValue))
                } else {
                    pending.continuation.yield(object["result"] ?? .null)
                    pending.continuation.finish()
                }
                return
            }

            if object["method"]?.stringValue == "notifications/progress",
               let params = object["params"],
               let token = params.progressToken,
               let handler = progressHandlers[token],
               let lane = progressLanes[token]
            {
                lane.submit(params, to: handler)
            }
        } catch {
            pendingRequests.failAll(error: Self.runtimeError(from: error))
        }
    }

    func sendCancellationNotification(for id: JSONRPC.ID) async {
        await authority.sendCancellationNotification(for: id)
    }

    func respondToUnsupportedServerRequest(id: JSONValue) async throws {
        let payload = try JSONRPC.Wire.errorResponseData(
            idValue: id,
            code: -32601,
            message: "Unsupported server request"
        )
        try await authority.send(MCPClientOperation(
            envelope: MCPClientEnvelope(data: payload),
            deadline: nil,
            replayPolicy: .never
        ))
    }

    func makeJSONRPCPayload(id: JSONRPC.ID?, method: String, params: JSONValue?) throws -> Data {
        let object: [String: Any] = id.map {
            JSONRPC.Wire.requestObject(id: $0, method: method, params: params)
        } ?? JSONRPC.Wire.notificationObject(method: method, params: params)
        return try JSONRPC.Wire.data(from: object)
    }

    func paramsByAddingProgressToken(_ token: String, to params: JSONValue?) throws -> JSONValue {
        guard let params else {
            return .object(["_meta": .object(["progressToken": .string(token)])])
        }
        guard case .object(var object) = params else {
            throw MCPBridgeRuntimeError.invalidRequest("progress requests require object params")
        }
        var meta: [String: JSONValue]
        if case .object(let existingMeta) = object["_meta"] { meta = existingMeta } else { meta = [:] }
        meta["progressToken"] = .string(token)
        object["_meta"] = .object(meta)
        return .object(object)
    }

    func parseJSONObject(_ data: Data) throws -> [String: JSONValue] {
        let raw = try JSONRPC.Wire.object(fromData: data)
        guard let value = JSONValue(any: raw), case .object(let object) = value else {
            throw MCPBridgeRuntimeError.invalidResponse("JSON-RPC message is not an object")
        }
        return object
    }

    func jsonRPCIDKey(_ value: JSONValue) -> String? {
        switch value {
        case .string(let value): value
        case .number(let value): value.stringValue
        case .object, .array, .bool, .null: nil
        }
    }

    func parseServerError(_ value: JSONValue) -> MCPBridgeRuntimeError {
        guard case .object(let object) = value else {
            return .invalidResponse("JSON-RPC error is not an object")
        }
        let code: Int
        switch object["code"] {
        case .number(.int(let value)): code = Int(value)
        case .number(.double(let value)): code = Int(value)
        default: code = 0
        }
        let message: String
        if case .string(let value) = object["message"] { message = value } else { message = "MCP server error" }
        return .serverError(code: code, message: message, data: object["data"])
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var progressToken: String? {
        guard case .object(let object) = self,
              case .string(let token) = object["progressToken"] else { return nil }
        return token
    }
}
