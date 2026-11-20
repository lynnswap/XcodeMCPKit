import XcodeMCPCore
import XcodeMCPWire
import Foundation
import Synchronization

package struct MCPConnectionID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package struct MCPClientEnvelope: Sendable {
    package enum Kind: Sendable {
        case request(id: JSONRPC.ID, method: String)
        case notification(method: String)
        case response(id: JSONRPC.ID)
    }

    package let kind: Kind
    package let data: Data

    package init(data: Data) throws {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MCPBridgeRuntimeError.invalidRequest("invalid JSON-RPC message: \(error.localizedDescription)")
        }
        guard let object = raw as? [String: Any] else {
            throw MCPBridgeRuntimeError.invalidRequest("JSON-RPC message must be one object")
        }
        let method = object["method"] as? String
        let id = object["id"].flatMap(JSONRPC.ID.init(any:))
        if let method, let id {
            kind = .request(id: id, method: method)
        } else if let method {
            kind = .notification(method: method)
        } else if let id {
            kind = .response(id: id)
        } else {
            throw MCPBridgeRuntimeError.invalidRequest("JSON-RPC message has neither method nor id")
        }
        self.data = data
    }

    package var requestID: JSONRPC.ID? {
        guard case .request(let id, _) = kind else { return nil }
        return id
    }

    package var responseID: JSONRPC.ID? {
        guard case .response(let id) = kind else { return nil }
        return id
    }

    package var method: String? {
        switch kind {
        case .request(_, let method), .notification(let method): method
        case .response: nil
        }
    }
}

package enum MCPReplayPolicy: Sendable, Equatable {
    case never
    case onceWhenRejectedBeforeProcessing
}

package enum MCPClientSessionFailure: Error, Sendable, Equatable {
    case sessionRecoveryFailed(String)
}

package struct MCPClientOperation: Sendable {
    package let envelope: MCPClientEnvelope
    package let deadline: Deadline?
    package let replayPolicy: MCPReplayPolicy

    package init(
        envelope: MCPClientEnvelope,
        deadline: Deadline?,
        replayPolicy: MCPReplayPolicy
    ) {
        self.envelope = envelope
        self.deadline = deadline
        self.replayPolicy = replayPolicy
    }
}

package struct MCPManagedInitializeContext: Sendable {
    package let clientName: String
    package let clientVersion: String
    package let capabilities: [String: JSONValue]

    package init(clientName: String, clientVersion: String, capabilities: [String: JSONValue]) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.capabilities = capabilities
    }
}

package struct MCPTransportRecipe: Sendable {
    package let makeTransport: @Sendable () async throws -> any XcodeMCPTransport

    package init(
        makeTransport: @escaping @Sendable () async throws -> any XcodeMCPTransport
    ) {
        self.makeTransport = makeTransport
    }
}

package enum MCPClientSessionEvent: Sendable {
    case message(connection: MCPConnectionID, envelope: MCPClientEnvelope)
    case connectionState(XcodeMCPConnectionState)
}

private final class MCPConnectionSubscriberRegistry: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<XcodeMCPConnectionState>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    func makeStream(initial: XcodeMCPConnectionState) -> AsyncStream<XcodeMCPConnectionState> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: XcodeMCPConnectionState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let shouldFinish = state.withLock { state in
            guard state.isFinished == false else { return true }
            state.continuations[id] = pair.continuation
            return false
        }
        pair.continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        pair.continuation.yield(initial)
        if shouldFinish { pair.continuation.finish() }
        return pair.stream
    }

    func publish(_ snapshot: XcodeMCPConnectionState) {
        let current = state.withLock { Array($0.continuations.values) }
        for continuation in current {
            continuation.yield(snapshot)
        }
    }

    func finish() {
        let current = state.withLock { state
            -> [AsyncStream<XcodeMCPConnectionState>.Continuation] in
            guard state.isFinished == false else { return [] }
            state.isFinished = true
            let values = Array(state.continuations.values)
            state.continuations.removeAll()
            return values
        }
        for continuation in current {
            continuation.finish()
        }
    }
}

private final class MCPConnectionOperationAdmission: Sendable {
    private struct State {
        var cancel: (@Sendable () -> Void)?
        var isCancellationRequested = false
        var isTerminal = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func installCancellation(_ cancel: @escaping @Sendable () -> Void) {
        let shouldCancel = state.withLock { state in
            // The closure captures the task, whose operation captures this admission.
            // A terminal admission must never retain it and recreate that cycle.
            guard state.isTerminal == false else { return false }
            state.cancel = cancel
            return state.isCancellationRequested
        }
        if shouldCancel { cancel() }
    }

    func cancel() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.isCancellationRequested = true
            return state.cancel
        }
        cancel?()
    }

    func finish() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.isTerminal == false else { return [] }
            state.isTerminal = true
            state.cancel = nil
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let isTerminal = state.withLock { state in
                guard state.isTerminal == false else { return true }
                state.waiters.append(continuation)
                return false
            }
            if isTerminal { continuation.resume() }
        }
    }

    func waitUntilTerminal() async {
        await waitUntilClosed()
    }
}

private final class MCPConnectionCommandIngress: Sendable {
    private struct State {
        var isAccepting = true
        var operations: [UUID: MCPConnectionOperationAdmission] = [:]
        var closeTask: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func admit() throws -> (id: UUID, admission: MCPConnectionOperationAdmission) {
        try state.withLock { state in
            guard state.isAccepting else { throw MCPBridgeRuntimeError.closed }
            let id = UUID()
            let admission = MCPConnectionOperationAdmission()
            state.operations[id] = admission
            return (id, admission)
        }
    }

    func operationFinished(id: UUID) {
        _ = state.withLock { $0.operations.removeValue(forKey: id) }
    }

    func closeTask(
        make: (_ operations: [MCPConnectionOperationAdmission]) -> Task<Void, Never>
    ) -> Task<Void, Never> {
        state.withLock { state in
            if let closeTask = state.closeTask { return closeTask }
            state.isAccepting = false
            let task = make(Array(state.operations.values))
            state.closeTask = task
            return task
        }
    }

    func cancel() {
        let snapshot = state.withLock { state in
            state.isAccepting = false
            return (Array(state.operations.values), state.closeTask)
        }
        for operation in snapshot.0 { operation.cancel() }
        snapshot.1?.cancel()
    }
}

package actor MCPClientSessionAuthority {
    private actor Connection {
        nonisolated let id: MCPConnectionID
        nonisolated let generation: UInt64
        nonisolated let eventTask: Task<Void, Never>

        private let transport: any XcodeMCPTransport
        private nonisolated let ingress = MCPConnectionCommandIngress()

        init(
            id: MCPConnectionID,
            generation: UInt64,
            transport: any XcodeMCPTransport,
            onEvent: @escaping @Sendable (XcodeMCPTransportEvent) async -> Void
        ) {
            self.id = id
            self.generation = generation
            self.transport = transport
            let events = transport.events
            self.eventTask = Task {
                for await event in events {
                    guard Task.isCancelled == false else { return }
                    await onEvent(event)
                }
            }
        }

        nonisolated func send(
            _ data: Data,
            headers: MCPConnectionHeaders,
            deadline: Deadline?
        ) throws -> Task<Void, Error> {
            let admitted = try ingress.admit()
            let task = Task<Void, Error> {
                defer {
                    admitted.admission.finish()
                    ingress.operationFinished(id: admitted.id)
                }
                try Task.checkCancellation()
                try await self.performSend(data, headers: headers, deadline: deadline)
            }
            admitted.admission.installCancellation { task.cancel() }
            return task
        }

        nonisolated func startEventStream(
            headers: MCPConnectionHeaders
        ) throws -> Task<Void, Error> {
            let admitted = try ingress.admit()
            let task = Task<Void, Error> {
                defer {
                    admitted.admission.finish()
                    ingress.operationFinished(id: admitted.id)
                }
                try Task.checkCancellation()
                await self.performStartEventStream(headers: headers)
            }
            admitted.admission.installCancellation { task.cancel() }
            return task
        }

        nonisolated func close(headers: MCPConnectionHeaders) -> Task<Void, Never> {
            ingress.closeTask { operations in
                Task {
                    for operation in operations { operation.cancel() }
                    let rawClose = Task { await self.performClose(headers: headers) }
                    for operation in operations { await operation.waitUntilTerminal() }
                    await rawClose.value
                }
            }
        }

        nonisolated func cancel() {
            ingress.cancel()
            eventTask.cancel()
        }

        private func performSend(
            _ data: Data,
            headers: MCPConnectionHeaders,
            deadline: Deadline?
        ) async throws {
            try await transport.send(data, headers: headers, deadline: deadline)
        }

        private func performStartEventStream(headers: MCPConnectionHeaders) async {
            await transport.startEventStream(headers: headers)
        }

        private func performClose(headers: MCPConnectionHeaders) async {
            eventTask.cancel()
            await transport.close(headers: headers)
            await eventTask.value
        }
    }

    /// One attempt to replace the connection.
    ///
    /// Callers wait for it without owning it. It ends when the replacement is ready, when
    /// its deadline passes, or when the session closes.
    private struct Recovery {
        let id: UUID
        let attempt: Task<Void, Never>
        /// Fails the recovery at its deadline, whichever step the attempt has reached.
        let deadline: Task<Void, Never>
        /// The replacement, once the attempt has installed it as the current connection.
        var connectionID: MCPConnectionID?
        var waiters: [UUID: AsyncThrowingStream<Void, Error>.Continuation] = [:]
    }

    private enum HiddenRequestStep: Sendable {
        case sendCompleted
        case response(MCPClientEnvelope)
    }

    package nonisolated let events: AsyncStream<MCPClientSessionEvent>

    private let eventContinuation: AsyncStream<MCPClientSessionEvent>.Continuation
    private let recipe: MCPTransportRecipe
    private let initialize: MCPManagedInitializeContext
    private let clock: ClockClient
    /// Bounds a recovery like the first connection.
    private let recoveryTimeout: Duration
    private let subscribers = MCPConnectionSubscriberRegistry()

    private var current: Connection?
    private var currentHeaders = MCPConnectionHeaders()
    private var generation: UInt64 = 0
    private var snapshot = XcodeMCPConnectionState(
        generation: 0,
        phase: .initializing
    )
    private var isClosed = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var hiddenResponses: [String: AsyncThrowingStream<MCPClientEnvelope, Error>.Continuation] = [:]
    private var recovery: Recovery?
    /// Work that failed recoveries left behind, such as a transport that is still being
    /// created. `close()` waits for it.
    private var recoveryCleanups: [UUID: Task<Void, Never>] = [:]
    private var cancellationNotificationTasks: [UUID: Task<Void, Never>] = [:]

    private init(
        recipe: MCPTransportRecipe,
        initialize: MCPManagedInitializeContext,
        defaultTimeout: Duration?,
        clock: ClockClient
    ) {
        let pair = AsyncStream.makeStream(of: MCPClientSessionEvent.self)
        self.events = pair.stream
        self.eventContinuation = pair.continuation
        self.recipe = recipe
        self.initialize = initialize
        self.clock = clock
        self.recoveryTimeout = defaultTimeout ?? .seconds(30)
    }

    package static func startManaged(
        recipe: MCPTransportRecipe,
        initialize: MCPManagedInitializeContext,
        defaultTimeout: Duration?,
        clock: ClockClient = .liveValue
    ) async throws -> MCPClientSessionAuthority {
        let authority = MCPClientSessionAuthority(
            recipe: recipe,
            initialize: initialize,
            defaultTimeout: defaultTimeout,
            clock: clock
        )
        do {
            try await authority.openManaged(
                deadline: Deadline.fromNow(defaultTimeout ?? .seconds(30), clock: clock)
            )
            return authority
        } catch {
            await authority.close()
            throw error
        }
    }

    package func send(_ operation: MCPClientOperation) async throws {
        try ensureOpen()
        try checkDeadline(operation.deadline, method: operation.envelope.method ?? "response")
        let connection = try await connectionForOperation(deadline: operation.deadline)
        do {
            try await sendOnce(operation.envelope, on: connection, deadline: operation.deadline)
        } catch let failure as MCPTransportFailure {
            guard case .sessionExpired(_, let delivery) = failure,
                  delivery == .rejectedBeforeProcessing,
                  operation.replayPolicy == .onceWhenRejectedBeforeProcessing
            else {
                throw failure
            }
            try await joinRecovery(failedConnection: connection.id, deadline: operation.deadline)
            guard let replacement = current else { throw MCPBridgeRuntimeError.closed }
            do {
                try await sendOnce(operation.envelope, on: replacement, deadline: operation.deadline)
            } catch let secondFailure as MCPTransportFailure {
                if case .sessionExpired(let sessionID, _) = secondFailure {
                    let reason = "replacement session \(sessionID) expired before replay completed"
                    publish(.unavailable(.sessionRecoveryFailed(reason)))
                    throw MCPClientSessionFailure.sessionRecoveryFailed(reason)
                }
                throw secondFailure
            }
        }
    }

    package func reconnect(deadline: Deadline?) async throws {
        if isClosed { throw MCPBridgeRuntimeError.closed }
        try await joinRecovery(failedConnection: current?.id, deadline: deadline, force: true)
    }

    package func connectionState() -> XcodeMCPConnectionState {
        snapshot
    }

    package func connectionStates() -> AsyncStream<XcodeMCPConnectionState> {
        subscribers.makeStream(initial: snapshot)
    }

    package func sendCancellationNotification(for requestID: JSONRPC.ID) {
        guard isClosed == false, let connection = current else { return }
        let data: Data
        do {
            data = try JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(
                method: "notifications/cancelled",
                params: .object(["requestId": requestID.value])
            ))
        } catch {
            return
        }
        let id = UUID()
        let headers = currentHeaders
        let deadline = Deadline.fromNow(.seconds(1), clock: clock)
        guard let sendTask = try? connection.send(data, headers: headers, deadline: deadline) else {
            return
        }
        let notificationClock = clock
        cancellationNotificationTasks[id] = Task { [weak self] in
            await Self.performBestEffortSend(
                sendTask: sendTask,
                clock: notificationClock
            )
            await self?.cancellationNotificationFinished(id: id)
        }
    }

    package func close() async {
        guard isClosed == false else {
            guard closeCompleted == false else { return }
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        isClosed = true
        let interruptedRecovery = recovery
        recovery = nil
        interruptedRecovery?.attempt.cancel()
        interruptedRecovery?.deadline.cancel()
        for waiter in interruptedRecovery?.waiters.values.map({ $0 }) ?? [] {
            waiter.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        let cleanups = Array(recoveryCleanups.values)
        recoveryCleanups.removeAll()
        let connection = current
        let headers = currentHeaders
        current = nil
        currentHeaders = MCPConnectionHeaders()
        for continuation in hiddenResponses.values {
            continuation.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        hiddenResponses.removeAll()
        let cancellationTasks = Array(cancellationNotificationTasks.values)
        cancellationNotificationTasks.removeAll()
        for task in cancellationTasks { task.cancel() }
        if let connection {
            await Self.closeConnection(connection, headers: headers)
        }
        await interruptedRecovery?.attempt.value
        for cleanup in cleanups { await cleanup.value }
        for task in cancellationTasks { await task.value }
        publish(.closed)
        subscribers.finish()
        eventContinuation.finish()
        closeCompleted = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    isolated deinit {
        recovery?.attempt.cancel()
        recovery?.deadline.cancel()
        current?.cancel()
        for task in cancellationNotificationTasks.values { task.cancel() }
        for continuation in hiddenResponses.values {
            continuation.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        subscribers.finish()
        eventContinuation.finish()
        for waiter in closeWaiters { waiter.resume() }
    }
}

private extension MCPClientSessionAuthority {
    private nonisolated static func closeConnection(
        _ connection: Connection,
        headers: MCPConnectionHeaders
    ) async {
        await connection.close(headers: headers).value
    }

    nonisolated static func awaitConnectionCommand(
        _ task: Task<Void, Error>
    ) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func performBestEffortSend(
        sendTask: Task<Void, Error>,
        clock: ClockClient
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await awaitConnectionCommand(sendTask)
            }
            group.addTask {
                await clock.sleep(.seconds(1))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    func cancellationNotificationFinished(id: UUID) {
        cancellationNotificationTasks.removeValue(forKey: id)
    }

    private func openManaged(deadline: Deadline?) async throws {
        let transport: any XcodeMCPTransport
        do {
            transport = try await recipe.makeTransport()
        } catch {
            try Task.checkCancellation()
            throw error
        }
        guard Task.isCancelled == false else {
            await transport.close(headers: MCPConnectionHeaders())
            throw CancellationError()
        }
        let connection = installConnection(transport, phase: .initializing)
        try await performManagedHandshake(initialize, on: connection, deadline: deadline)
        publish(.ready)
    }

    private func connectionForOperation(deadline: Deadline?) async throws -> Connection {
        if recovery != nil {
            try await joinRecovery(failedConnection: nil, deadline: deadline)
        }
        guard let current else {
            throw MCPBridgeRuntimeError.transportUnavailable("MCP connection is unavailable")
        }
        return current
    }

    private func installConnection(
        _ transport: any XcodeMCPTransport,
        phase: XcodeMCPConnectionState.Phase
    ) -> Connection {
        generation &+= 1
        let connectionID = MCPConnectionID()
        let connectionGeneration = generation
        let connection = Connection(
            id: connectionID,
            generation: connectionGeneration,
            transport: transport
        ) { [weak self] event in
            await self?.handle(
                event,
                connectionID: connectionID,
                generation: connectionGeneration
            )
        }
        current = connection
        currentHeaders = MCPConnectionHeaders()
        publish(phase)
        return connection
    }

    private func sendOnce(
        _ envelope: MCPClientEnvelope,
        on connection: Connection,
        deadline: Deadline?
    ) async throws {
        guard current?.id == connection.id else {
            throw MCPTransportFailure.unavailable("connection was replaced before send")
        }
        try checkDeadline(deadline, method: envelope.method ?? "response")
        let sendTask = try connection.send(
            envelope.data,
            headers: currentHeaders,
            deadline: deadline
        )
        do {
            try await Self.awaitConnectionCommand(sendTask)
        } catch let failure as MCPTransportFailure {
            throw failure
        } catch let error as MCPBridgeRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPTransportFailure.deliveryUnknown(error.localizedDescription)
        }
    }

    private func performManagedHandshake(
        _ context: MCPManagedInitializeContext,
        on connection: Connection,
        deadline: Deadline?
    ) async throws {
        let id = JSONRPC.ID(any: "xcode-mcp-internal-\(UUID().uuidString)")!
        let payload = try JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocolVersion.current),
                "clientInfo": .object([
                    "name": .string(context.clientName),
                    "version": .string(context.clientVersion),
                ]),
                "capabilities": .object(Self.filteredCapabilities(context.capabilities)),
            ])
        ))
        let response = try await sendHiddenRequest(
            MCPClientEnvelope(data: payload),
            responseIDKey: id.key,
            connection: connection,
            deadline: deadline
        )
        let protocolVersion = try Self.validateInitializeResponse(response)
        currentHeaders.protocolVersion = protocolVersion
        let initialized = try MCPClientEnvelope(data: JSONRPC.Wire.data(from:
            JSONRPC.Wire.notificationObject(method: "notifications/initialized")
        ))
        try await sendOnce(initialized, on: connection, deadline: deadline)
        try await startEventStreamOnce(on: connection, headers: currentHeaders)
    }

    private func sendHiddenRequest(
        _ envelope: MCPClientEnvelope,
        responseIDKey: String,
        connection: Connection,
        deadline: Deadline?
    ) async throws -> MCPClientEnvelope {
        guard current?.id == connection.id else {
            throw MCPTransportFailure.unavailable("connection was replaced during initialize")
        }
        try checkDeadline(deadline, method: "initialize")
        let pair = AsyncThrowingStream.makeStream(of: MCPClientEnvelope.self, throwing: Error.self)
        hiddenResponses[responseIDKey] = pair.continuation
        defer {
            hiddenResponses.removeValue(forKey: responseIDKey)
            pair.continuation.finish()
        }
        let data = envelope.data
        let headers = currentHeaders
        let sendTask = try connection.send(data, headers: headers, deadline: deadline)
        let responseStream = pair.stream
        let operation: @Sendable () async throws -> MCPClientEnvelope = {
            try await withTaskCancellationHandler {
                return try await withThrowingTaskGroup(of: HiddenRequestStep.self) { group in
                    group.addTask {
                        try await Self.awaitConnectionCommand(sendTask)
                        return .sendCompleted
                    }
                    group.addTask {
                        for try await response in responseStream {
                            return .response(response)
                        }
                        try Task.checkCancellation()
                        throw MCPBridgeRuntimeError.transportUnavailable(
                            "connection closed during initialize"
                        )
                    }
                    while let step = try await group.next() {
                        switch step {
                        case .sendCompleted:
                            continue
                        case .response(let response):
                            group.cancelAll()
                            return response
                        }
                    }
                    throw MCPBridgeRuntimeError.transportUnavailable(
                        "connection closed during initialize"
                    )
                }
            } onCancel: {
                pair.continuation.finish(throwing: CancellationError())
            }
        }
        return try await raceDeadline(
            deadline,
            method: "initialize",
            operation: operation
        )
    }

    private func startEventStreamOnce(
        on connection: Connection,
        headers: MCPConnectionHeaders
    ) async throws {
        guard current?.id == connection.id else {
            throw MCPTransportFailure.unavailable("connection was replaced before event stream start")
        }
        let task = try connection.startEventStream(headers: headers)
        try await Self.awaitConnectionCommand(task)
    }

    /// Waits for the connection to be replaced, starting a recovery when none is running.
    ///
    /// The caller's deadline and cancellation end only its own wait.
    func joinRecovery(
        failedConnection: MCPConnectionID?,
        deadline: Deadline?,
        force: Bool = false
    ) async throws {
        if force == false, let failedConnection, current?.id != failedConnection,
           recovery == nil
        {
            // Another caller already replaced the connection that failed.
            return
        }
        if isClosed { throw MCPBridgeRuntimeError.closed }
        try checkDeadline(deadline, method: "session recovery")
        let recoveryID = recovery?.id ?? startRecovery()
        let waiterID = UUID()
        let pair = AsyncThrowingStream.makeStream(of: Void.self, throwing: Error.self)
        recovery?.waiters[waiterID] = pair.continuation
        defer { leaveRecovery(waiterID: waiterID, recoveryID: recoveryID) }
        do {
            try await raceDeadline(deadline, method: "session recovery") {
                for try await _ in pair.stream { return }
                try Task.checkCancellation()
                throw MCPBridgeRuntimeError.transportUnavailable("session recovery ended without a result")
            }
        } catch let error as MCPBridgeRuntimeError {
            if case .requestTimedOut = error { throw error }
            throw MCPClientSessionFailure.sessionRecoveryFailed(error.localizedDescription)
        } catch let failure as MCPClientSessionFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPClientSessionFailure.sessionRecoveryFailed(error.localizedDescription)
        }
    }

    private func leaveRecovery(waiterID: UUID, recoveryID: UUID) {
        guard recovery?.id == recoveryID else { return }
        recovery?.waiters.removeValue(forKey: waiterID)?.finish()
    }

    /// Detaches the current connection and starts replacing it.
    private func startRecovery() -> UUID {
        precondition(recovery == nil, "only one recovery may run")
        let id = UUID()
        let retired = current
        let retiredHeaders = currentHeaders
        current = nil
        currentHeaders = MCPConnectionHeaders()
        publish(.recovering)
        let recipe = recipe
        // The task holds the session only while it installs and initializes the replacement,
        // so a session that is released while a transport is being created can go away.
        let attempt = Task { [weak self] in
            if let retired {
                await Self.closeConnection(retired, headers: retiredHeaders)
            }
            do {
                try Task.checkCancellation()
                let transport = try await recipe.makeTransport()
                guard let self else {
                    await transport.close(headers: MCPConnectionHeaders())
                    return
                }
                try await self.initializeRecoveredTransport(transport, recoveryID: id)
                await self.completeRecovery(id: id)
            } catch {
                await self?.failRecovery(id: id, reason: error.localizedDescription)
            }
        }
        let timeout = recoveryTimeout
        let clock = clock
        let deadline = Task { [weak self] in
            await clock.sleep(timeout)
            guard Task.isCancelled == false else { return }
            await self?.failRecovery(id: id, reason: "session recovery timed out")
        }
        recovery = Recovery(id: id, attempt: attempt, deadline: deadline)
        return id
    }

    private func initializeRecoveredTransport(
        _ transport: any XcodeMCPTransport,
        recoveryID: UUID
    ) async throws {
        guard recovery?.id == recoveryID, isClosed == false, Task.isCancelled == false else {
            // The recovery ended while the transport was being created.
            await transport.close(headers: MCPConnectionHeaders())
            throw CancellationError()
        }
        let connection = installConnection(transport, phase: .recovering)
        recovery?.connectionID = connection.id
        try await performManagedHandshake(initialize, on: connection, deadline: nil)
    }

    private func completeRecovery(id: UUID) {
        guard let completed = recovery, completed.id == id,
              let connectionID = completed.connectionID, current?.id == connectionID
        else { return }
        recovery = nil
        completed.deadline.cancel()
        publish(.ready)
        for waiter in completed.waiters.values {
            waiter.yield(())
            waiter.finish()
        }
    }

    /// Ends a recovery as failed. The attempt may still be running: its remaining work and
    /// its replacement are released in a cleanup that `close()` waits for, so a later
    /// reconnect can start at once.
    private func failRecovery(id: UUID, reason: String) {
        guard let failed = recovery, failed.id == id else { return }
        recovery = nil
        failed.deadline.cancel()
        failed.attempt.cancel()
        var replacement: (connection: Connection, headers: MCPConnectionHeaders)?
        if let connection = current, connection.id == failed.connectionID {
            replacement = (connection, currentHeaders)
            current = nil
            currentHeaders = MCPConnectionHeaders()
        }
        publish(.unavailable(.sessionRecoveryFailed(reason)))
        for waiter in failed.waiters.values {
            waiter.finish(throwing: MCPClientSessionFailure.sessionRecoveryFailed(reason))
        }
        let attempt = failed.attempt
        recoveryCleanups[id] = Task { [weak self, replacement] in
            if let replacement {
                await Self.closeConnection(replacement.connection, headers: replacement.headers)
            }
            await attempt.value
            await self?.recoveryCleanupEnded(id: id)
        }
    }

    private func recoveryCleanupEnded(id: UUID) {
        recoveryCleanups.removeValue(forKey: id)
    }

    func handle(
        _ event: XcodeMCPTransportEvent,
        connectionID: MCPConnectionID,
        generation eventGeneration: UInt64
    ) async {
        guard current?.id == connectionID, generation == eventGeneration, isClosed == false else {
            return
        }
        switch event {
        case .message(let data):
            await handleMessage(
                data,
                responseHeaders: MCPConnectionHeaders(),
                connectionID: connectionID
            )
        case .messageWithHeaders(let data, let responseHeaders):
            await handleMessage(
                data,
                responseHeaders: responseHeaders,
                connectionID: connectionID
            )
        case .sessionExpired:
            beginBackgroundRecovery(failedConnection: connectionID)
        case .closed(let reason):
            publish(.unavailable(.transportUnavailable(reason ?? "transport closed")))
        }
    }

    func handleMessage(
        _ data: Data,
        responseHeaders: MCPConnectionHeaders,
        connectionID: MCPConnectionID
    ) async {
            do {
                let envelope = try MCPClientEnvelope(data: data)
                if case .response(let id) = envelope.kind,
                   hiddenResponses[id.key] != nil,
                   let sessionID = responseHeaders.sessionID,
                   sessionID.isEmpty == false
                {
                    currentHeaders.sessionID = sessionID
                }
                if case .response(let id) = envelope.kind,
                   let continuation = hiddenResponses.removeValue(forKey: id.key)
                {
                    continuation.yield(envelope)
                    continuation.finish()
                    return
                }
                eventContinuation.yield(.message(connection: connectionID, envelope: envelope))
            } catch {
                publish(.unavailable(.invalidResponse(error.localizedDescription)))
            }
    }

    func beginBackgroundRecovery(failedConnection: MCPConnectionID) {
        guard isClosed == false, recovery == nil, current?.id == failedConnection else { return }
        _ = startRecovery()
    }

    nonisolated static func validateInitializeResponse(_ envelope: MCPClientEnvelope) throws -> String {
        let object = try JSONRPC.Wire.object(fromData: envelope.data)
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            let message = error["message"] as? String ?? "MCP server error"
            throw MCPBridgeRuntimeError.serverError(
                code: code,
                message: message,
                data: error["data"].flatMap(JSONValue.init(any:))
            )
        } else if object["error"] != nil {
            throw MCPBridgeRuntimeError.invalidResponse("initialize error is not an object")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw MCPBridgeRuntimeError.invalidResponse("initialize result is not an object")
        }
        guard let protocolVersion = result["protocolVersion"] as? String,
              protocolVersion.isEmpty == false else {
            throw MCPBridgeRuntimeError.invalidResponse(
                "initialize result is missing protocolVersion"
            )
        }
        guard MCPProtocolVersion.isSupported(protocolVersion) else {
            throw MCPBridgeRuntimeError.invalidResponse(
                "initialize result has unsupported protocolVersion \(protocolVersion)"
            )
        }
        return protocolVersion
    }

    nonisolated static func filteredCapabilities(
        _ capabilities: [String: JSONValue]
    ) -> [String: JSONValue] {
        capabilities.filter { key, _ in
            key != "roots" && key != "sampling" && key != "elicitation"
        }
    }

    func ensureOpen() throws {
        if isClosed { throw MCPBridgeRuntimeError.closed }
        if case .unavailable(let error) = snapshot.phase {
            throw error.sessionError
        }
    }

    func checkDeadline(_ deadline: Deadline?, method: String) throws {
        if deadline?.hasExpired == true {
            throw MCPBridgeRuntimeError.requestTimedOut(method: method)
        }
    }

    func raceDeadline<T: Sendable>(
        _ deadline: Deadline?,
        method: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let deadline else { return try await operation() }
        try checkDeadline(deadline, method: method)
        let clock = clock
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

    func publish(_ phase: XcodeMCPConnectionState.Phase) {
        snapshot = XcodeMCPConnectionState(
            generation: generation,
            phase: phase
        )
        subscribers.publish(snapshot)
        eventContinuation.yield(.connectionState(snapshot))
    }
}

extension XcodeMCPError {
    /// The session-layer error that fails requests while the connection reports this error
    /// as unavailable.
    var sessionError: any Error {
        switch self {
        case .sessionRecoveryFailed(let reason):
            MCPClientSessionFailure.sessionRecoveryFailed(reason)
        case .transportUnavailable(let reason):
            MCPBridgeRuntimeError.transportUnavailable(reason)
        case .invalidResponse(let reason):
            MCPBridgeRuntimeError.invalidResponse(reason)
        case .closed, .invalidRequest, .requestTimedOut, .serverError:
            self
        }
    }
}
