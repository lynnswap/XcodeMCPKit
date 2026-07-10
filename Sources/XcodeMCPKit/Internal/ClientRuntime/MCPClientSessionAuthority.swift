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

package enum MCPClientInitializationMode: Sendable {
    case managed(MCPManagedInitializeContext)
    case forwarded
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
    case connectionState(XcodeMCPConnectionSnapshot)
}

package protocol MCPRecoveryLeaseScheduling: Sendable {
    func schedule(
        after duration: Duration,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>
}

package struct ClockMCPRecoveryLeaseScheduler: MCPRecoveryLeaseScheduling {
    private let clock: ClockClient

    package init(clock: ClockClient) {
        self.clock = clock
    }

    package func schedule(
        after duration: Duration,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            await clock.sleep(duration)
            guard Task.isCancelled == false else { return }
            await operation()
        }
    }
}

private final class MCPConnectionSubscriberRegistry: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<XcodeMCPConnectionSnapshot>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    func makeStream(initial: XcodeMCPConnectionSnapshot) -> AsyncStream<XcodeMCPConnectionSnapshot> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: XcodeMCPConnectionSnapshot.self,
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

    func publish(_ snapshot: XcodeMCPConnectionSnapshot) {
        let current = state.withLock { Array($0.continuations.values) }
        for continuation in current {
            continuation.yield(snapshot)
        }
    }

    func finish() {
        let current = state.withLock { state
            -> [AsyncStream<XcodeMCPConnectionSnapshot>.Continuation] in
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

private final class MCPConnectionCloseAuthority: Sendable {
    private struct State {
        var isClosing = false
        var isClosed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func close(_ operation: @escaping @Sendable () async -> Void) async {
        let ownsClose = state.withLock { state in
            guard state.isClosed == false, state.isClosing == false else { return false }
            state.isClosing = true
            return true
        }
        guard ownsClose else {
            await waitUntilClosed()
            return
        }
        await operation()
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isClosed = true
            state.isClosing = false
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let isClosed = state.withLock { state in
                guard state.isClosed == false else { return true }
                state.waiters.append(continuation)
                return false
            }
            if isClosed { continuation.resume() }
        }
    }
}

package actor MCPClientSessionAuthority {
    private struct Connection {
        let id: MCPConnectionID
        let generation: UInt64
        let transport: any XcodeMCPTransport
        let eventTask: Task<Void, Never>
        let closeAuthority: MCPConnectionCloseAuthority
    }

    private struct ForwardedInitializeRecipe: Sendable {
        let requestData: Data
        let originalIDKey: String
        var responseValidated: Bool
        var initializedObserved: Bool
    }

    private enum RecoveryPhase {
        case active
        case finishing
        case abandoned
    }

    private struct RecoveryBackgroundLease {
        let id: UUID
        let task: Task<Void, Never>
        var isActive: Bool
    }

    private struct RecoveryState {
        let id: UUID
        let task: Task<Void, Never>
        var phase: RecoveryPhase
        var backgroundLease: RecoveryBackgroundLease?
        var cleanupTask: Task<Void, Never>?
        var ownedConnectionID: MCPConnectionID?
        var waiters: [UUID: AsyncThrowingStream<Void, Error>.Continuation]

        var hasLiveOwner: Bool {
            waiters.isEmpty == false || backgroundLease?.isActive == true
        }

        var isActive: Bool {
            if case .active = phase { return true }
            return false
        }
    }

    private struct RecoveryPlan: Sendable {
        let oldConnection: Connection?
        let oldHeaders: MCPConnectionHeaders
        let handshake: RecoveryHandshake
        let recipe: MCPTransportRecipe
        let clock: ClockClient
    }

    private enum RecoveryHandshake: Sendable {
        case managed(MCPManagedInitializeContext)
        case forwarded(ForwardedInitializeRecipe)
    }

    private struct HiddenHandshake: Sendable {
        let request: MCPClientEnvelope
        let responseIDKey: String
        let sendsInitialized: Bool
    }

    private enum RecoveryConnectionInstallation {
        case installed(Connection)
        case rejected
    }

    private enum HiddenRequestStep: Sendable {
        case sendCompleted
        case response(MCPClientEnvelope)
    }

    package nonisolated let events: AsyncStream<MCPClientSessionEvent>

    private let eventContinuation: AsyncStream<MCPClientSessionEvent>.Continuation
    private let recipe: MCPTransportRecipe
    private let initializationMode: MCPClientInitializationMode
    private let clock: ClockClient
    private let backgroundRecoveryTimeout: Duration
    private let recoveryLeaseScheduler: any MCPRecoveryLeaseScheduling
    private let subscribers = MCPConnectionSubscriberRegistry()

    private var current: Connection?
    private var currentHeaders = MCPConnectionHeaders()
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var snapshot = XcodeMCPConnectionSnapshot(
        sequence: 0,
        generation: 0,
        phase: .initializing
    )
    private var isClosed = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var hiddenResponses: [String: AsyncThrowingStream<MCPClientEnvelope, Error>.Continuation] = [:]
    private var forwardedInitialize: ForwardedInitializeRecipe?
    private var forwardedInitializeFailure: MCPBridgeRuntimeError?
    private var forwardedResponseWaiters: [UUID: AsyncThrowingStream<Void, Error>.Continuation] = [:]
    private var forwardedReadyWaiters: [UUID: AsyncThrowingStream<Void, Error>.Continuation] = [:]
    private var recovery: RecoveryState?
    private var cancellationNotificationTasks: [UUID: Task<Void, Never>] = [:]

    private init(
        recipe: MCPTransportRecipe,
        mode: MCPClientInitializationMode,
        defaultTimeout: Duration?,
        recoveryLeaseScheduler: (any MCPRecoveryLeaseScheduling)?,
        clock: ClockClient
    ) {
        let pair = AsyncStream.makeStream(of: MCPClientSessionEvent.self)
        self.events = pair.stream
        self.eventContinuation = pair.continuation
        self.recipe = recipe
        self.initializationMode = mode
        self.clock = clock
        self.backgroundRecoveryTimeout = defaultTimeout ?? .seconds(30)
        self.recoveryLeaseScheduler = recoveryLeaseScheduler
            ?? ClockMCPRecoveryLeaseScheduler(clock: clock)
    }

    package static func startManaged(
        recipe: MCPTransportRecipe,
        initialize: MCPManagedInitializeContext,
        defaultTimeout: Duration?,
        recoveryLeaseScheduler: (any MCPRecoveryLeaseScheduling)? = nil,
        clock: ClockClient = .liveValue
    ) async throws -> MCPClientSessionAuthority {
        let authority = MCPClientSessionAuthority(
            recipe: recipe,
            mode: .managed(initialize),
            defaultTimeout: defaultTimeout,
            recoveryLeaseScheduler: recoveryLeaseScheduler,
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

    package static func makeForwarded(
        recipe: MCPTransportRecipe,
        defaultTimeout: Duration? = nil,
        recoveryLeaseScheduler: (any MCPRecoveryLeaseScheduling)? = nil,
        clock: ClockClient = .liveValue
    ) -> MCPClientSessionAuthority {
        MCPClientSessionAuthority(
            recipe: recipe,
            mode: .forwarded,
            defaultTimeout: defaultTimeout,
            recoveryLeaseScheduler: recoveryLeaseScheduler,
            clock: clock
        )
    }

    package func send(_ operation: MCPClientOperation) async throws {
        try ensureOpen()
        try checkDeadline(operation.deadline, method: operation.envelope.method ?? "response")
        if case .forwarded = initializationMode,
           forwardedInitialize == nil
        {
            guard case .request(_, let method) = operation.envelope.kind,
                  method == "initialize" else {
                throw MCPBridgeRuntimeError.invalidRequest(
                    "forwarded MCP session requires initialize before other messages"
                )
            }
        }
        if case .forwarded = initializationMode,
           case .request(let id, let method) = operation.envelope.kind,
           method == "initialize"
        {
            guard forwardedInitialize == nil else {
                throw MCPBridgeRuntimeError.invalidRequest(
                    "forwarded MCP session accepts initialize only once"
                )
            }
            forwardedInitialize = ForwardedInitializeRecipe(
                requestData: operation.envelope.data,
                originalIDKey: id.key,
                responseValidated: false,
                initializedObserved: false
            )
        }
        if case .forwarded = initializationMode,
           forwardedInitialize != nil
        {
            switch operation.envelope.kind {
            case .request(_, let method) where method == "initialize":
                break
            case .notification(let method) where method == "notifications/initialized":
                try await waitForForwardedResponse(deadline: operation.deadline)
            case .response:
                try await waitForForwardedResponse(deadline: operation.deadline)
            case .request, .notification:
                try await waitForForwardedReady(deadline: operation.deadline)
            }
        }
        let connection = try await connectionForOperation(
            operation.envelope,
            deadline: operation.deadline
        )
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
        if case .forwarded = initializationMode,
           case .notification(let method) = operation.envelope.kind,
           method == "notifications/initialized"
        {
            await current?.transport.startEventStream(headers: currentHeaders)
            markForwardedInitialized()
        }
    }

    package func reconnect(deadline: Deadline?) async throws {
        if isClosed { throw MCPBridgeRuntimeError.closed }
        try await joinRecovery(failedConnection: current?.id, deadline: deadline, force: true)
    }

    package func connectionState() -> XcodeMCPConnectionSnapshot {
        snapshot
    }

    package func connectionStates() -> AsyncStream<XcodeMCPConnectionSnapshot> {
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
        let transport = connection.transport
        let headers = currentHeaders
        let deadline = Deadline.fromNow(.seconds(1), clock: clock)
        let notificationClock = clock
        cancellationNotificationTasks[id] = Task { [weak self] in
            await Self.performBestEffortSend(
                transport: transport,
                data: data,
                headers: headers,
                deadline: deadline,
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
        let recoveryState = recovery
        recoveryState?.task.cancel()
        recoveryState?.backgroundLease?.task.cancel()
        let recoveryWaiters = recoveryState.map { Array($0.waiters.values) } ?? []
        recovery = nil
        for waiter in recoveryWaiters {
            waiter.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        let connection = current
        let headers = currentHeaders
        current = nil
        currentHeaders = MCPConnectionHeaders()
        for continuation in hiddenResponses.values {
            continuation.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        hiddenResponses.removeAll()
        let forwardedWaiters = Array(forwardedResponseWaiters.values)
            + Array(forwardedReadyWaiters.values)
        forwardedResponseWaiters.removeAll()
        forwardedReadyWaiters.removeAll()
        for waiter in forwardedWaiters {
            waiter.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        let cancellationTasks = Array(cancellationNotificationTasks.values)
        cancellationNotificationTasks.removeAll()
        for task in cancellationTasks { task.cancel() }
        if let connection {
            await Self.closeConnection(connection, headers: headers)
        }
        await recoveryState?.cleanupTask?.value
        await recoveryState?.backgroundLease?.task.value
        await recoveryState?.task.value
        for task in cancellationTasks { await task.value }
        publish(.closed(.requested))
        subscribers.finish()
        eventContinuation.finish()
        closeCompleted = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    isolated deinit {
        recovery?.task.cancel()
        recovery?.backgroundLease?.task.cancel()
        current?.eventTask.cancel()
        for task in cancellationNotificationTasks.values { task.cancel() }
        for continuation in hiddenResponses.values {
            continuation.finish(throwing: MCPBridgeRuntimeError.closed)
        }
        for continuation in forwardedResponseWaiters.values { continuation.finish() }
        for continuation in forwardedReadyWaiters.values { continuation.finish() }
        subscribers.finish()
        eventContinuation.finish()
        for waiter in closeWaiters { waiter.resume() }
    }
}

private extension MCPClientSessionAuthority {
    private nonisolated static func closeDetachedConnection(_ plan: RecoveryPlan) async throws {
        guard let connection = plan.oldConnection else { return }
        await closeConnection(connection, headers: plan.oldHeaders)
        try Task.checkCancellation()
    }

    private nonisolated static func closeConnection(
        _ connection: Connection,
        headers: MCPConnectionHeaders
    ) async {
        await connection.closeAuthority.close {
            connection.eventTask.cancel()
            await connection.transport.close(headers: headers)
            await connection.eventTask.value
        }
    }

    private nonisolated static func makeHiddenRecoveryHandshake(
        _ handshake: RecoveryHandshake
    ) throws -> HiddenHandshake {
        let id = "xcode-mcp-recovery-\(UUID().uuidString)"
        let payload: Data
        let sendsInitialized: Bool
        switch handshake {
        case .managed(let context):
            payload = try JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(
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
            sendsInitialized = true
        case .forwarded(let forwarded):
            var object = try JSONRPC.Wire.object(fromData: forwarded.requestData)
            object["id"] = id
            payload = try JSONRPC.Wire.data(from: object)
            sendsInitialized = forwarded.initializedObserved
        }
        return HiddenHandshake(
            request: try MCPClientEnvelope(data: payload),
            responseIDKey: id,
            sendsInitialized: sendsInitialized
        )
    }

    nonisolated static func performDetachedHiddenRequest(
        _ request: MCPClientEnvelope,
        responseStream: AsyncThrowingStream<MCPClientEnvelope, Error>,
        transport: any XcodeMCPTransport,
        headers: MCPConnectionHeaders,
        deadline: Deadline?,
        clock: ClockClient
    ) async throws -> MCPClientEnvelope {
        let operation: @Sendable () async throws -> MCPClientEnvelope = {
            try await withThrowingTaskGroup(of: HiddenRequestStep.self) { group in
                group.addTask {
                    try await transport.send(
                        request.data,
                        headers: headers,
                        deadline: deadline
                    )
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
        }
        guard let deadline else { return try await operation() }
        guard deadline.hasExpired == false else {
            throw MCPBridgeRuntimeError.requestTimedOut(method: "initialize")
        }
        return try await withThrowingTaskGroup(of: MCPClientEnvelope.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                await clock.sleep(deadline.remainingDuration())
                try Task.checkCancellation()
                throw MCPBridgeRuntimeError.requestTimedOut(method: "initialize")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    nonisolated static func initializedNotificationEnvelope() throws -> MCPClientEnvelope {
        try MCPClientEnvelope(data: JSONRPC.Wire.data(from:
            JSONRPC.Wire.notificationObject(method: "notifications/initialized")
        ))
    }

    nonisolated static func performBestEffortSend(
        transport: any XcodeMCPTransport,
        data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?,
        clock: ClockClient
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await transport.send(data, headers: headers, deadline: deadline)
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
        let connection = try await installFreshConnection(phase: .initializing)
        guard case .managed(let context) = initializationMode else {
            preconditionFailure("managed open requires managed initialization mode")
        }
        try await performManagedHandshake(context, on: connection, deadline: deadline)
        publish(.ready)
    }

    private func connectionForOperation(
        _ envelope: MCPClientEnvelope,
        deadline: Deadline?
    ) async throws -> Connection {
        if recovery != nil {
            try await joinRecovery(failedConnection: nil, deadline: deadline)
        }
        if let current {
            return current
        }
        guard case .forwarded = initializationMode else {
            throw MCPBridgeRuntimeError.transportUnavailable("MCP connection is unavailable")
        }
        let connection = try await installFreshConnection(phase: .initializing)
        if forwardedInitialize == nil,
           case .request(let id, let method) = envelope.kind,
           method == "initialize"
        {
            forwardedInitialize = ForwardedInitializeRecipe(
                requestData: envelope.data,
                originalIDKey: id.key,
                responseValidated: false,
                initializedObserved: false
            )
        }
        return connection
    }

    private func installFreshConnection(phase: XcodeMCPConnectionSnapshot.Phase) async throws -> Connection {
        let transport = try await recipe.makeTransport()
        return installConnection(transport, phase: phase)
    }

    private func installConnection(
        _ transport: any XcodeMCPTransport,
        phase: XcodeMCPConnectionSnapshot.Phase
    ) -> Connection {
        generation &+= 1
        let connectionID = MCPConnectionID()
        let connectionGeneration = generation
        let transportEvents = transport.events
        let eventTask = Task { [weak self] in
            for await event in transportEvents {
                guard Task.isCancelled == false else { return }
                await self?.handle(event, connectionID: connectionID, generation: connectionGeneration)
            }
        }
        let connection = Connection(
            id: connectionID,
            generation: connectionGeneration,
            transport: transport,
            eventTask: eventTask,
            closeAuthority: MCPConnectionCloseAuthority()
        )
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
        do {
            try await connection.transport.send(
                envelope.data,
                headers: currentHeaders,
                deadline: deadline
            )
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
        let id = "xcode-mcp-internal-\(UUID().uuidString)"
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
            responseIDKey: id,
            connection: connection,
            deadline: deadline
        )
        let protocolVersion = try Self.validateInitializeResponse(response)
        currentHeaders.protocolVersion = protocolVersion
        let initialized = try MCPClientEnvelope(data: JSONRPC.Wire.data(from:
            JSONRPC.Wire.notificationObject(method: "notifications/initialized")
        ))
        try await sendOnce(initialized, on: connection, deadline: deadline)
        await connection.transport.startEventStream(headers: currentHeaders)
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
        let transport = connection.transport
        let data = envelope.data
        let headers = currentHeaders
        let responseStream = pair.stream
        let operation: @Sendable () async throws -> MCPClientEnvelope = {
            try await withTaskCancellationHandler {
                return try await withThrowingTaskGroup(of: HiddenRequestStep.self) { group in
                    group.addTask {
                        try await transport.send(
                            data,
                            headers: headers,
                            deadline: deadline
                        )
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

    func joinRecovery(
        failedConnection: MCPConnectionID?,
        deadline: Deadline?,
        force: Bool = false
    ) async throws {
        if force == false, let failedConnection, current?.id != failedConnection,
           recovery == nil
        {
            return
        }
        try checkDeadline(deadline, method: "session recovery")
        while let stale = recovery, stale.isActive == false {
            await stale.task.value
            if isClosed { throw MCPBridgeRuntimeError.closed }
            if force == false { try ensureOpen() }
            try checkDeadline(deadline, method: "session recovery")
        }
        if force == false, let failedConnection, current?.id != failedConnection,
           recovery == nil
        {
            return
        }
        let waiterID = UUID()
        let pair = AsyncThrowingStream.makeStream(of: Void.self, throwing: Error.self)
        guard let recoveryID = ensureRecovery(
            replacing: failedConnection,
            waiter: (waiterID, pair.continuation),
            requestsBackgroundLease: false
        ) else {
            throw MCPBridgeRuntimeError.transportUnavailable("session recovery did not start")
        }
        defer { leaveRecoveryWaiter(id: waiterID, recoveryID: recoveryID) }
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

    func ensureRecovery(
        replacing failedConnection: MCPConnectionID?,
        waiter: (
            id: UUID,
            continuation: AsyncThrowingStream<Void, Error>.Continuation
        )?,
        requestsBackgroundLease: Bool
    ) -> UUID? {
        precondition(waiter != nil || requestsBackgroundLease)
        if var state = recovery {
            guard state.isActive else { return nil }
            if let waiter {
                state.waiters[waiter.id] = waiter.continuation
            }
            recovery = state
            if requestsBackgroundLease {
                attachBackgroundLeaseIfNeeded(recoveryID: state.id)
            }
            return state.id
        }
        publish(.recovering)
        let id = UUID()
        let task = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                guard let plan = try await self?.prepareRecovery(
                    replacing: failedConnection,
                    recoveryID: id
                ) else { return }
                try await Self.closeDetachedConnection(plan)
                try Task.checkCancellation()
                guard try await self?.authorizeRecovery(recoveryID: id) == true else {
                    return
                }
                let transport = try await plan.recipe.makeTransport()
                do {
                    try Task.checkCancellation()
                    guard try await self?.authorizeRecovery(recoveryID: id) == true else {
                        await transport.close(headers: MCPConnectionHeaders())
                        return
                    }
                } catch {
                    await transport.close(headers: MCPConnectionHeaders())
                    throw error
                }
                guard let installation = await self?.installRecoveredConnection(
                    transport,
                    recoveryID: id
                ) else {
                    await transport.close(headers: MCPConnectionHeaders())
                    return
                }
                let connection: Connection
                switch installation {
                case .installed(let installed):
                    connection = installed
                case .rejected:
                    await transport.close(headers: MCPConnectionHeaders())
                    throw CancellationError()
                }
                let handshake = try Self.makeHiddenRecoveryHandshake(plan.handshake)
                guard let responseStream = try await self?.registerHiddenResponse(
                    idKey: handshake.responseIDKey,
                    connectionID: connection.id,
                    recoveryID: id
                ) else {
                    await Self.closeConnection(connection, headers: MCPConnectionHeaders())
                    return
                }
                let response: MCPClientEnvelope
                do {
                    guard let initializeHeaders = try await self?.authorizeRecoveryConnection(
                        connection.id,
                        recoveryID: id
                    ) else {
                        await Self.closeConnection(
                            connection,
                            headers: MCPConnectionHeaders()
                        )
                        return
                    }
                    response = try await Self.performDetachedHiddenRequest(
                        handshake.request,
                        responseStream: responseStream,
                        transport: connection.transport,
                        headers: initializeHeaders,
                        deadline: nil,
                        clock: plan.clock
                    )
                    guard try await self?.authorizeRecoveryConnection(
                        connection.id,
                        recoveryID: id
                    ) != nil else {
                        await Self.closeConnection(connection, headers: initializeHeaders)
                        return
                    }
                } catch {
                    await self?.removeHiddenResponse(idKey: handshake.responseIDKey)
                    if let failed = await self?.detachRecoveryConnectionIfOwned(
                        connectionID: connection.id,
                        recoveryID: id
                    ) {
                        await Self.closeConnection(failed.connection, headers: failed.headers)
                    } else if self == nil {
                        await Self.closeConnection(
                            connection,
                            headers: MCPConnectionHeaders()
                        )
                    }
                    throw error
                }
                await self?.removeHiddenResponse(idKey: handshake.responseIDKey)
                try Task.checkCancellation()
                let protocolVersion = try Self.validateInitializeResponse(response)
                guard let headers = try await self?.acceptRecoveryProtocolVersion(
                    protocolVersion,
                    connectionID: connection.id,
                    recoveryID: id
                ) else {
                    await Self.closeConnection(connection, headers: MCPConnectionHeaders())
                    return
                }
                if handshake.sendsInitialized {
                    let initialized = try Self.initializedNotificationEnvelope()
                    guard let initializedHeaders = try await self?.authorizeRecoveryConnection(
                        connection.id,
                        recoveryID: id
                    ) else {
                        await Self.closeConnection(connection, headers: headers)
                        return
                    }
                    try await connection.transport.send(
                        initialized.data,
                        headers: initializedHeaders,
                        deadline: nil
                    )
                    guard let eventStreamHeaders = try await self?.authorizeRecoveryConnection(
                        connection.id,
                        recoveryID: id
                    ) else {
                        await Self.closeConnection(connection, headers: initializedHeaders)
                        return
                    }
                    await connection.transport.startEventStream(headers: eventStreamHeaders)
                    guard try await self?.authorizeRecoveryConnection(
                        connection.id,
                        recoveryID: id
                    ) != nil else {
                        await Self.closeConnection(connection, headers: eventStreamHeaders)
                        return
                    }
                }
                let completion = await self?.completeRecoveryConnection(
                    connection.id,
                    recoveryID: id,
                    isReady: handshake.sendsInitialized
                )
                guard completion != nil else {
                    await Self.closeConnection(connection, headers: headers)
                    return
                }
                guard completion == true else {
                    throw MCPTransportFailure.unavailable(
                        "connection was replaced before recovery completed"
                    )
                }
                result = .success(())
            } catch {
                if let failed = await self?.detachFailedRecoveryConnection(recoveryID: id) {
                    await Self.closeConnection(failed.connection, headers: failed.headers)
                }
                result = .failure(error)
            }
            await self?.finishRecovery(id: id, result: result)
        }
        var waiters: [UUID: AsyncThrowingStream<Void, Error>.Continuation] = [:]
        if let waiter {
            waiters[waiter.id] = waiter.continuation
        }
        recovery = RecoveryState(
            id: id,
            task: task,
            phase: .active,
            backgroundLease: nil,
            cleanupTask: nil,
            ownedConnectionID: failedConnection,
            waiters: waiters
        )
        if requestsBackgroundLease {
            attachBackgroundLeaseIfNeeded(recoveryID: id)
        }
        return id
    }

    func finishRecovery(id: UUID, result: Result<Void, Error>) async {
        guard var state = recovery, state.id == id else { return }
        let wasAbandoned: Bool
        switch state.phase {
        case .active:
            state.phase = .finishing
            wasAbandoned = false
        case .finishing:
            wasAbandoned = false
        case .abandoned:
            wasAbandoned = true
        }
        if var lease = state.backgroundLease {
            lease.isActive = false
            lease.task.cancel()
            state.backgroundLease = lease
        }
        let cleanupTask = state.cleanupTask
        let backgroundTask = state.backgroundLease?.task
        recovery = state
        await cleanupTask?.value
        await backgroundTask?.value

        guard let currentState = recovery, currentState.id == id else { return }
        recovery = nil
        if case .failure(let error) = result, wasAbandoned == false, isClosed == false {
            publish(.unavailable(.sessionRecoveryFailed(error.localizedDescription)))
        }
        for waiter in currentState.waiters.values {
            switch result {
            case .success:
                waiter.yield(())
                waiter.finish()
            case .failure(let error):
                waiter.finish(throwing: MCPClientSessionFailure.sessionRecoveryFailed(
                    error.localizedDescription
                ))
            }
        }
    }

    private func detachFailedRecoveryConnection(
        recoveryID: UUID
    ) -> (connection: Connection, headers: MCPConnectionHeaders)? {
        guard var state = recovery,
              state.id == recoveryID,
              let connection = current,
              state.ownedConnectionID == connection.id else { return nil }
        let headers = currentHeaders
        current = nil
        currentHeaders = MCPConnectionHeaders()
        state.ownedConnectionID = nil
        recovery = state
        return (connection, headers)
    }

    private func detachRecoveryConnectionIfOwned(
        connectionID: MCPConnectionID,
        recoveryID: UUID
    ) -> (connection: Connection, headers: MCPConnectionHeaders)? {
        guard var state = recovery,
              state.id == recoveryID,
              state.ownedConnectionID == connectionID,
              let connection = current,
              connection.id == connectionID else { return nil }
        let headers = currentHeaders
        current = nil
        currentHeaders = MCPConnectionHeaders()
        state.ownedConnectionID = nil
        recovery = state
        return (connection, headers)
    }

    private func authorizeRecovery(recoveryID: UUID) throws -> Bool {
        guard let state = recovery,
              state.id == recoveryID,
              state.isActive,
              state.hasLiveOwner,
              isClosed == false else { throw CancellationError() }
        return true
    }

    private func authorizeRecoveryConnection(
        _ connectionID: MCPConnectionID,
        recoveryID: UUID
    ) throws -> MCPConnectionHeaders {
        guard let state = recovery,
              state.id == recoveryID,
              state.isActive,
              state.hasLiveOwner,
              state.ownedConnectionID == connectionID,
              current?.id == connectionID,
              isClosed == false else { throw CancellationError() }
        return currentHeaders
    }

    private func attachBackgroundLeaseIfNeeded(recoveryID: UUID) {
        guard var state = recovery,
              state.id == recoveryID,
              state.isActive,
              state.backgroundLease == nil else { return }
        let leaseID = UUID()
        let timeout = backgroundRecoveryTimeout
        let task = recoveryLeaseScheduler.schedule(after: timeout) { [weak self] in
            await self?.backgroundRecoveryLeaseExpired(
                recoveryID: recoveryID,
                leaseID: leaseID
            )
        }
        state.backgroundLease = RecoveryBackgroundLease(
            id: leaseID,
            task: task,
            isActive: true
        )
        recovery = state
    }

    private func backgroundRecoveryLeaseExpired(recoveryID: UUID, leaseID: UUID) {
        guard var state = recovery,
              state.id == recoveryID,
              state.isActive,
              var lease = state.backgroundLease,
              lease.id == leaseID,
              lease.isActive else { return }
        lease.isActive = false
        state.backgroundLease = lease
        recovery = state
        guard state.hasLiveOwner == false else { return }
        abandonRecovery(
            recoveryID: recoveryID,
            reason: "background session recovery timed out"
        )
    }

    private func abandonRecovery(recoveryID: UUID, reason: String) {
        guard var state = recovery,
              state.id == recoveryID,
              state.isActive else { return }
        state.phase = .abandoned
        if var lease = state.backgroundLease {
            lease.isActive = false
            lease.task.cancel()
            state.backgroundLease = lease
        }
        if let connection = current,
           state.ownedConnectionID == connection.id
        {
            let headers = currentHeaders
            current = nil
            currentHeaders = MCPConnectionHeaders()
            state.ownedConnectionID = nil
            state.cleanupTask = Task.detached {
                await Self.closeConnection(connection, headers: headers)
            }
        }
        for continuation in hiddenResponses.values {
            continuation.finish(throwing: CancellationError())
        }
        hiddenResponses.removeAll()
        let recoveryTask = state.task
        recovery = state
        recoveryTask.cancel()
        if isClosed == false {
            publish(.unavailable(.sessionRecoveryFailed(reason)))
        }
    }

    func leaveRecoveryWaiter(id: UUID, recoveryID: UUID) {
        guard var state = recovery, state.id == recoveryID else { return }
        state.waiters.removeValue(forKey: id)?.finish()
        recovery = state
        if state.isActive, state.hasLiveOwner == false {
            abandonRecovery(
                recoveryID: recoveryID,
                reason: "session recovery abandoned after its final owner left"
            )
        }
    }

    private func prepareRecovery(
        replacing failedConnection: MCPConnectionID?,
        recoveryID: UUID
    ) throws -> RecoveryPlan {
        guard var state = recovery,
              state.id == recoveryID,
              state.isActive,
              state.hasLiveOwner,
              isClosed == false else { throw CancellationError() }
        if let failedConnection, current?.id != failedConnection {
            throw MCPTransportFailure.unavailable("connection was replaced before recovery")
        }
        let handshake: RecoveryHandshake
        switch initializationMode {
        case .managed(let context):
            handshake = .managed(context)
        case .forwarded:
            guard let forwardedInitialize, forwardedInitialize.responseValidated else {
                throw MCPBridgeRuntimeError.invalidResponse(
                    "cannot recover a forwarded session before initialize succeeds"
                )
            }
            handshake = .forwarded(forwardedInitialize)
        }
        let old = current
        let oldHeaders = currentHeaders
        current = nil
        currentHeaders = MCPConnectionHeaders()
        state.ownedConnectionID = nil
        recovery = state
        return RecoveryPlan(
            oldConnection: old,
            oldHeaders: oldHeaders,
            handshake: handshake,
            recipe: recipe,
            clock: clock
        )
    }

    private func installRecoveredConnection(
        _ transport: any XcodeMCPTransport,
        recoveryID: UUID
    ) -> RecoveryConnectionInstallation {
        guard var state = recovery,
              state.id == recoveryID,
              state.isActive,
              state.hasLiveOwner,
              isClosed == false,
              current == nil else { return .rejected }
        let connection = installConnection(transport, phase: .recovering)
        state.ownedConnectionID = connection.id
        recovery = state
        return .installed(connection)
    }

    func registerHiddenResponse(
        idKey: String,
        connectionID: MCPConnectionID,
        recoveryID: UUID
    ) throws -> AsyncThrowingStream<MCPClientEnvelope, Error> {
        _ = try authorizeRecoveryConnection(connectionID, recoveryID: recoveryID)
        let pair = AsyncThrowingStream.makeStream(of: MCPClientEnvelope.self, throwing: Error.self)
        hiddenResponses[idKey]?.finish(
            throwing: MCPBridgeRuntimeError.invalidResponse("duplicate hidden request ID")
        )
        hiddenResponses[idKey] = pair.continuation
        return pair.stream
    }

    func removeHiddenResponse(idKey: String) {
        hiddenResponses.removeValue(forKey: idKey)?.finish()
    }

    func acceptRecoveryProtocolVersion(
        _ protocolVersion: String,
        connectionID: MCPConnectionID,
        recoveryID: UUID
    ) throws -> MCPConnectionHeaders {
        _ = try authorizeRecoveryConnection(connectionID, recoveryID: recoveryID)
        currentHeaders.protocolVersion = protocolVersion
        return currentHeaders
    }

    func completeRecoveryConnection(
        _ connectionID: MCPConnectionID,
        recoveryID: UUID,
        isReady: Bool
    ) -> Bool {
        guard var state = recovery,
              state.id == recoveryID,
              state.isActive,
              state.hasLiveOwner,
              state.ownedConnectionID == connectionID,
              current?.id == connectionID,
              isClosed == false else { return false }
        state.phase = .finishing
        recovery = state
        publish(isReady ? .ready : .initializing)
        return true
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
                   hiddenResponses[id.key] != nil || id.key == forwardedInitialize?.originalIDKey,
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
                observeForwardedHandshake(envelope)
                eventContinuation.yield(.message(connection: connectionID, envelope: envelope))
            } catch {
                publish(.unavailable(.protocolViolation(error.localizedDescription)))
            }
    }

    func beginBackgroundRecovery(failedConnection: MCPConnectionID) {
        guard isClosed == false else { return }
        _ = ensureRecovery(
            replacing: failedConnection,
            waiter: nil,
            requestsBackgroundLease: true
        )
    }

    func observeForwardedHandshake(_ envelope: MCPClientEnvelope) {
        guard var forwardedInitialize else { return }
        switch envelope.kind {
        case .response(let id) where id.key == forwardedInitialize.originalIDKey:
            do {
                let protocolVersion = try Self.validateInitializeResponse(envelope)
                currentHeaders.protocolVersion = protocolVersion
                forwardedInitialize.responseValidated = true
                forwardedInitializeFailure = nil
                finishForwardedWaiters(&forwardedResponseWaiters, result: .success(()))
            } catch let error as MCPBridgeRuntimeError {
                forwardedInitializeFailure = error
                finishForwardedWaiters(&forwardedResponseWaiters, result: .failure(error))
                finishForwardedWaiters(&forwardedReadyWaiters, result: .failure(error))
            } catch {
                let runtimeError = MCPBridgeRuntimeError.invalidResponse(error.localizedDescription)
                forwardedInitializeFailure = runtimeError
                finishForwardedWaiters(&forwardedResponseWaiters, result: .failure(runtimeError))
                finishForwardedWaiters(&forwardedReadyWaiters, result: .failure(runtimeError))
            }
            self.forwardedInitialize = forwardedInitialize
            if forwardedInitialize.responseValidated, forwardedInitialize.initializedObserved {
                publish(.ready)
                finishForwardedWaiters(&forwardedReadyWaiters, result: .success(()))
            }
        default:
            break
        }
    }

    func markForwardedInitialized() {
        guard var forwardedInitialize else { return }
        forwardedInitialize.initializedObserved = true
        self.forwardedInitialize = forwardedInitialize
        if forwardedInitialize.responseValidated {
            publish(.ready)
            finishForwardedWaiters(&forwardedReadyWaiters, result: .success(()))
        }
    }

    func waitForForwardedResponse(deadline: Deadline?) async throws {
        if let failure = forwardedInitializeFailure { throw failure }
        if forwardedInitialize?.responseValidated == true { return }
        let id = UUID()
        let pair = AsyncThrowingStream.makeStream(of: Void.self, throwing: Error.self)
        forwardedResponseWaiters[id] = pair.continuation
        defer { forwardedResponseWaiters.removeValue(forKey: id)?.finish() }
        try await waitForForwardedState(pair.stream, deadline: deadline)
    }

    func waitForForwardedReady(deadline: Deadline?) async throws {
        if let failure = forwardedInitializeFailure { throw failure }
        if forwardedInitialize?.responseValidated == true,
           forwardedInitialize?.initializedObserved == true { return }
        let id = UUID()
        let pair = AsyncThrowingStream.makeStream(of: Void.self, throwing: Error.self)
        forwardedReadyWaiters[id] = pair.continuation
        defer { forwardedReadyWaiters.removeValue(forKey: id)?.finish() }
        try await waitForForwardedState(pair.stream, deadline: deadline)
    }

    func waitForForwardedState(
        _ stream: AsyncThrowingStream<Void, Error>,
        deadline: Deadline?
    ) async throws {
        try await raceDeadline(deadline, method: "initialize") {
            for try await _ in stream { return }
            try Task.checkCancellation()
            throw MCPBridgeRuntimeError.transportUnavailable("forwarded initialize wait ended")
        }
    }

    func finishForwardedWaiters(
        _ waiters: inout [UUID: AsyncThrowingStream<Void, Error>.Continuation],
        result: Result<Void, Error>
    ) {
        let current = Array(waiters.values)
        waiters.removeAll()
        for waiter in current {
            switch result {
            case .success:
                waiter.yield(())
                waiter.finish()
            case .failure(let error):
                waiter.finish(throwing: error)
            }
        }
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
        if case .unavailable(let failure) = snapshot.phase {
            switch failure {
            case .sessionRecoveryFailed(let reason):
                throw MCPClientSessionFailure.sessionRecoveryFailed(reason)
            case .transportUnavailable(let reason):
                throw MCPBridgeRuntimeError.transportUnavailable(reason)
            case .protocolViolation(let reason):
                throw MCPBridgeRuntimeError.invalidResponse(reason)
            }
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

    func publish(_ phase: XcodeMCPConnectionSnapshot.Phase) {
        sequence &+= 1
        snapshot = XcodeMCPConnectionSnapshot(
            sequence: sequence,
            generation: generation,
            phase: phase
        )
        subscribers.publish(snapshot)
        eventContinuation.yield(.connectionState(snapshot))
    }
}
