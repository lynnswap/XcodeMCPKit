import Foundation
import NIOCore
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

package final class NativeHostBroker: ProxyRuntimeServing, Sendable {
    typealias SessionFactory = @Sendable (NativeHostRuntime.Configuration) -> any UpstreamSessionFactory

    private struct State: Sendable {
        var hosts: [String: NativeBrokerHost] = [:]
        var installations: [URL: String] = [:]
        var guiProcesses: [XcodeGUIProcess.Identity: String] = [:]
        var sessions: [ProxySessionID: NativeBrokerSession] = [:]
        var closing: [UUID: Task<Void, Never>] = [:]
        var stopped = false
        var resetsInProgress = 0
        var publicCatalog: JSONValue?
    }
    private let state = NIOLockedValueBox(State())
    /// Headless models whose native close is in flight. Binding, close election, and failed-close
    /// restoration all run under this lock, which is taken before the broker and session locks.
    private let closingWorkspaces = NIOLockedValueBox<Set<NativeBrokerWorkspace.Scope>>([])
    private let eventSource = ProxyRuntimeEventSource()
    private let configuration: ProxyRuntimeConfiguration
    private let inventory: XcodeHostInventory
    private let sessionFactory: SessionFactory
    private let clock: ClockClient
    private let logger = ProxyLogging.make("broker")
    static let defaultHostIdentifier = "host-default"
    static let listTool = "XcodeMCPKitListHosts"
    static let listWorkspacesTool = "XcodeListWorkspaces"
    static let openWorkspaceTool = "XcodeOpenWorkspace"
    static let closeWorkspaceTool = "XcodeCloseWorkspace"

    private struct Admission: Sendable {
        let hostIdentifier: String
        let workspace: NativeBrokerWorkspace?
        let deviceSession: NativeBrokerDeviceSession?
        let launchSession: NativeBrokerLaunchSession?
        let error: String?
        /// Whether this request counts as a reference to `workspace` while it runs.
        let retainsWorkspace: Bool
    }

    package convenience init(configuration: ProxyRuntimeConfiguration) throws {
        let environment = ProcessInfo.processInfo.environment
        try self.init(configuration: configuration,
                      inventory: XcodeHostInventory.live(configuration: configuration)) {
            NativeHostSessionFactory(configuration: $0, environment: environment)
        }
    }

    init(configuration: ProxyRuntimeConfiguration, inventory: XcodeHostInventory,
         clock: ClockClient = .liveValue, sessionFactory: @escaping SessionFactory) throws {
        self.configuration = configuration
        self.inventory = inventory
        self.sessionFactory = sessionFactory
        self.clock = clock
        _ = try register(installation: inventory.defaultInstallation, identifier: Self.defaultHostIdentifier)
    }

    /// Returns the one host for an installation's headless models or for a running GUI process.
    private func register(installation: XcodeHostInstallation, identifier: String? = nil,
                          guiProcess: XcodeGUIProcess? = nil) throws -> NativeBrokerHost {
        try state.withLockedValue { storage in
            guard !storage.stopped else { throw CancellationError() }
            if let guiProcess, let id = storage.guiProcesses[guiProcess.identity],
               let host = storage.hosts[id] { return host }
            if guiProcess == nil, let id = storage.installations[installation.developerDirectory],
               let host = storage.hosts[id] { return host }
            let id = identifier ?? "host-" + UUID().uuidString
            let processConfiguration = NativeHostRuntime.Configuration(
                nativeHostBundleURL: configuration.nativeHostBundleURL, guiProcess: guiProcess,
                developerDirectoryURL: installation.developerDirectory,
                sharesCompilationCache: configuration.sharesCompilationCache,
                maxBodyBytes: configuration.maxMessageBytes)
            let timeout = configuration.requestTimeout
            let connection = NativeHostConnection(
                factory: sessionFactory(processConfiguration),
                handshake: .object(InitializeHandshakeJSON.resolved(
                    initializeParamsOverride: configuration.initializeParamsOverride)),
                handshakeTimeout: MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: timeout).map(Self.duration),
                catalogTimeout: MCP.MethodDispatcher.timeoutForMethod("tools/list", defaultSeconds: timeout).map(Self.duration),
                prewarmsCatalog: configuration.prewarmToolsList, clock: clock,
                logger: ProxyLogging.make("native-host"),
                onEvent: { [weak self] event in self?.receive(event, from: id) })
            let host = NativeBrokerHost(identifier: id, index: (storage.hosts.values.map(\.index).max() ?? -1) + 1,
                installation: installation, guiProcess: guiProcess, connection: connection)
            storage.hosts[id] = host
            if let guiProcess { storage.guiProcesses[guiProcess.identity] = id }
            else { storage.installations[installation.developerDirectory] = id }
            return host
        }
    }

    private static func duration(_ amount: TimeAmount) -> Duration { .nanoseconds(amount.nanoseconds) }

    package func start() {
        guard let host = state.withLockedValue({ $0.hosts[Self.defaultHostIdentifier] }) else { return }
        // The connection owns the launch; this task only requests it so the first call finds a warm host.
        Task { try? await host.connection.start() }
    }

    package func subscribeToEvents(_ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void)
        -> @Sendable () -> Void { eventSource.subscribe(receive) }

    package func beginRequest(_ message: ProxyRuntimeRequest, in sessionID: ProxySessionID?)
        -> (any ProxyRuntimeRequestOperating)? {
        let object = message.decodedJSON?.foundationObject as? [String: Any]
        let requestID = object.flatMap { JSONRPC.Message.Inspector.requestID(from: $0) }
        var message = message
        if let object, case .request(let method, _) = JSONRPC.Message.Inspector.kind(of: object),
           let timeout = MCP.MethodDispatcher.timeoutForMethod(method, defaultSeconds: configuration.requestTimeout) {
            let deadline = clock.now().addingTimeInterval(Double(timeout.nanoseconds) / 1_000_000_000)
            message.deadline = message.deadline.map { min($0, deadline) } ?? deadline
        }
        let cancelled = ProxyRuntimeReply.mcpError(id: requestID, code: -32800,
            message: "request cancelled", sessionID: sessionID, prefersEventStream: message.prefersEventStream)
        guard let sessionID else {
            let stream = message.prefersEventStream
            return NativeHostBrokerOperation(cancelledReply: cancelled) {
                .mcpError(id: requestID, code: -32600, message: "invalid request",
                          sessionID: nil, prefersEventStream: stream)
            }
        }
        if !message.headerSessionExists {
            guard let object, case .request("initialize", _) = JSONRPC.Message.Inspector.kind(of: object),
                  !state.withLockedValue({ $0.stopped || $0.resetsInProgress > 0 }) else { return nil }
            let session = NativeBrokerSession(identifier: sessionID)
            let registered = state.withLockedValue { storage in
                guard !storage.stopped, storage.resetsInProgress == 0,
                      storage.sessions[sessionID] == nil else { return false }
                storage.sessions[sessionID] = session
                return true
            }
            if !registered { return nil }
            eventSource.emit(.sessionOpened(sessionID: sessionID))
        }
        guard let session = state.withLockedValue({ $0.resetsInProgress == 0 ? $0.sessions[sessionID] : nil }) else { return nil }
        let admission = session.state.withLockedValue { storage -> Admission? in
            guard !storage.closed else { return nil }
            storage.activeRequests += 1
            storage.activity = DispatchTime.now().uptimeNanoseconds
            let arguments = (object?["params"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
            let device = (arguments["interactionSessionKey"] as? String).flatMap { storage.deviceSessions[$0] }
            let launch = (arguments["launchSessionReference"] as? String).flatMap { storage.launchSessions[$0] }
            let workspace: NativeBrokerWorkspace?
            if let identifier = arguments["workspaceIdentifier"] as? String {
                workspace = storage.workspaces[identifier]
            } else {
                workspace = device?.workspace ?? launch?.workspace
            }
            let host = workspace?.hostIdentifier ?? device?.hostIdentifier ?? launch?.hostIdentifier
                ?? (arguments["hostIdentifier"] as? String) ?? Self.defaultHostIdentifier
            var error: String?
            if arguments["tabIdentifier"] != nil {
                error = "Use workspaceIdentifier returned by XcodeListWorkspaces instead of a native tabIdentifier"
            }
            if let value = arguments["workspaceIdentifier"] as? String, workspace == nil,
               !value.hasPrefix("/") {
                error = "Unknown workspaceIdentifier '\(value)'; call XcodeListWorkspaces or XcodeOpenWorkspace"
            }
            if let value = arguments["interactionSessionKey"] as? String, device == nil {
                error = "Unknown interactionSessionKey '\(value)'; start a device interaction session"
            }
            if let value = arguments["launchSessionReference"] as? String, launch == nil {
                error = "Unknown launchSessionReference '\(value)'; use a reference returned by RunProject"
            }
            if let workspace, let conflict = Self.workspaceConflict(workspace, device: device, launch: launch) {
                error = conflict
            }
            if let selector = ["hostIdentifier", "workspaceIdentifier", "interactionSessionKey", "launchSessionReference"].first(where: {
                arguments[$0] != nil && !(arguments[$0] is String)
            }) {
                error = "\(selector) must be a string"
            }
            storage.hostRequests[host, default: 0] += 1
            // A running request keeps its model open; a close request must not keep open what it closes.
            let name = (object?["params"] as? [String: Any])?["name"] as? String
            let retainsWorkspace = workspace != nil && name != Self.closeWorkspaceTool
            if let workspace, retainsWorkspace {
                storage.admittedWorkspaces[workspace.scope, default: 0] += 1
            }
            return Admission(hostIdentifier: host, workspace: workspace, deviceSession: device, launchSession: launch,
                             error: error, retainsWorkspace: retainsWorkspace)
        }
        guard let admission else { return nil }
        let key = UUID()
        let admittedMessage = message
        let timeoutReply = ProxyRuntimeReply.mcpError(id: requestID, code: -32000,
            message: "upstream timeout", sessionID: sessionID, prefersEventStream: message.prefersEventStream)
        let operation = NativeHostBrokerOperation(cancelledReply: cancelled, requestIDKey: requestID?.key,
            deadline: message.deadline, clock: clock, timeoutReply: timeoutReply) { [self] in
            let reply = await process(admittedMessage, in: session, admission: admission)
            session.releaseHost(admission.hostIdentifier)
            if let workspace = admission.workspace, admission.retainsWorkspace {
                session.releaseAdmission(of: workspace)
                // The request may have held the last reference after its session released the handle.
                if !state.withLockedValue({ $0.sessions.values.contains { $0.retainsNativeWorkspace(workspace) } }) {
                    scheduleUnreferencedClose([workspace])
                }
            }
            reapUnusedHosts()
            return reply
        }
        let retained = session.state.withLockedValue { storage in
            guard !storage.closed else { return false }
            storage.operations[key] = operation
            return true
        }
        if !retained { operation.cancel(reason: .channelInactive) }
        operation.whenWorkComplete {
            _ = session.state.withLockedValue { $0.operations.removeValue(forKey: key) }
        }
        return operation
    }

    private func process(_ request: ProxyRuntimeRequest, in session: NativeBrokerSession,
                         admission: Admission) async -> ProxyRuntimeReply {
        guard let json = request.decodedJSON else {
            return .mcpError(id: nil, code: -32700, message: "invalid json",
                            sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
        }
        guard let object = json.foundationObject as? [String: Any] else {
            return .mcpError(id: nil, code: -32600, message: "invalid request",
                            sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
        }
        let id = JSONRPC.Message.Inspector.requestID(from: object)
        do {
            try Task.checkCancellation()
            switch JSONRPC.Message.Inspector.kind(of: object) {
            case .request("initialize", _):
                session.state.withLockedValue { $0.protocolVersion = MCPProtocolVersion.current }
                return try Self.response(id: id, result: .object([
                    "protocolVersion": .string(MCPProtocolVersion.current),
                    "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "serverInfo": .object(["name": .string("XcodeMCPKit"), "version": .string("1")]),
                ]), session: session.identifier, eventStream: request.prefersEventStream)
            case .malformed(let invalidID):
                return .mcpError(id: invalidID, code: -32600, message: "invalid request",
                    sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
            case .notification("notifications/cancelled"):
                if let parameters = object["params"] as? [String: Any],
                   let cancelledID = Self.cancellationID(from: parameters["requestId"]) {
                    let operations = session.state.withLockedValue { Array($0.operations.values) }
                    for operation in operations where operation.requestIDKey == cancelledID.key {
                        operation.cancel(reason: .clientNotification)
                    }
                }
                return .accepted(sessionID: session.identifier)
            case .notification, .response:
                // The server sends no requests to clients, so a client response has nothing to answer.
                return .accepted(sessionID: session.identifier)
            case .request("ping", _):
                return try Self.response(id: id, result: .object([:]), session: session.identifier,
                                         eventStream: request.prefersEventStream)
            case .request("tools/list", _):
                if (object["params"] as? [String: Any])?["cursor"] != nil {
                    return .mcpError(id: id, code: -32602, message: "Invalid tools/list cursor",
                        sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
                }
                return try Self.response(id: id, result: await publicCatalog(session: session),
                                         session: session.identifier, eventStream: request.prefersEventStream)
            case .request("resources/list", _):
                return try Self.response(id: id, result: .object(["resources": .array([])]),
                                         session: session.identifier, eventStream: request.prefersEventStream)
            case .request("resources/templates/list", _):
                return try Self.response(id: id, result: .object(["resourceTemplates": .array([])]),
                                         session: session.identifier, eventStream: request.prefersEventStream)
            case .request("tools/call", _):
                if let arguments = (object["params"] as? [String: Any])?["arguments"],
                   !(arguments is [String: Any]) {
                    return .mcpError(id: id, code: -32602, message: "tools/call arguments must be an object",
                        sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
                }
                do {
                    if let error = admission.error { throw NativeHostBrokerError(error) }
                    return try await callTool(request, session: session, admission: admission)
                } catch let error as NativeHostBrokerReplyError {
                    return try Self.externalReply(error.reply, session: session.identifier, requestID: id)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return try Self.response(id: id, result: Self.toolResult(.object([
                        "message": .string(String(describing: error)),
                    ]), isError: true), session: session.identifier, eventStream: request.prefersEventStream)
                }
            case .request:
                return .mcpError(id: id, code: -32601, message: "Method not found",
                                 sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
            case .other:
                return .mcpError(id: id, code: -32600, message: "invalid request",
                                 sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
            }
        } catch let error as NativeHostBrokerReplyError {
            do {
                return try Self.externalReply(error.reply, session: session.identifier, requestID: id)
            } catch {
                return .failure(kind: .invalidUpstreamResponse, message: "Invalid native error response: \(error)",
                                sessionID: session.identifier)
            }
        } catch is CancellationError {
            return .mcpError(id: id, code: -32800, message: "request cancelled",
                            sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
        } catch {
            return .mcpError(id: id, code: -32000, message: String(describing: error),
                            sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
        }
    }

    /// The public catalog is fixed by the proxy; the default host only supplies native descriptions once.
    private func publicCatalog(session: NativeBrokerSession) async throws -> JSONValue {
        if let catalog = state.withLockedValue({ $0.publicCatalog }) { return catalog }
        guard let host = state.withLockedValue({ $0.hosts[Self.defaultHostIdentifier] }) else {
            throw NativeHostBrokerError("The default Xcode host is unavailable")
        }
        let native = try await withPinnedHost(host, session: session) { try await nativeCatalog(of: host).result }
        let catalog = try XcodeToolCatalog.publicResult(from: native, managementTools: Self.managementTools)
        return state.withLockedValue { storage in
            if storage.publicCatalog == nil { storage.publicCatalog = catalog }
            return storage.publicCatalog ?? catalog
        }
    }

    // MARK: - Host communication

    /// Converts connection failures into the replies clients have always received for them.
    private func communicate<T: Sendable>(with host: NativeBrokerHost,
                                          _ operation: () async throws -> T) async throws -> T {
        if let process = host.guiProcess, !inventory.isGUIProcessRunning(process) {
            throw NativeHostBrokerError("The workspace's Xcode process is no longer running")
        }
        do { return try await operation() }
        catch let error as NativeHostConnectionError {
            switch error {
            case .expired: throw Self.expiredReference()
            case .unavailable: throw Self.replyError(error, code: -32001, message: "upstream unavailable")
            case .overloaded: throw Self.replyError(error, code: -32002, message: "upstream overloaded")
            case .timedOut: throw Self.replyError(error, code: -32000, message: "upstream timeout")
            case .invalidResponse:
                throw NativeHostBrokerReplyError(description: error.description, reply: .failure(
                    kind: .invalidUpstreamResponse, message: error.description, sessionID: nil))
            case .rejected(let response):
                throw NativeHostBrokerReplyError(description: error.description, reply: .response(
                    data: response, sessionID: nil, prefersEventStream: false))
            }
        }
    }

    private static func replyError(_ error: NativeHostConnectionError, code: Int, message: String)
        -> NativeHostBrokerReplyError {
        NativeHostBrokerReplyError(description: error.description, reply: .mcpError(
            id: nil, code: code, message: message, sessionID: nil, prefersEventStream: false))
    }

    /// Starts the host's process if needed and returns its generation.
    private func runningGeneration(of host: NativeBrokerHost) async throws -> UInt64 {
        try await communicate(with: host) { try await host.connection.start() }
    }

    private func nativeCatalog(of host: NativeBrokerHost) async throws -> (generation: UInt64, result: JSONValue) {
        try await communicate(with: host) { try await host.connection.nativeCatalog() }
    }

    /// Sends a request to the host process with `generation` and returns its JSON-RPC response.
    private func send(_ request: JSONValue, to host: NativeBrokerHost, session: NativeBrokerSession,
                      generation: UInt64, eventStream: Bool) async throws -> ProxyRuntimeReply {
        let data = try await communicate(with: host) {
            try await host.connection.send(request, owner: session.identifier, generation: generation)
        }
        return .response(data: data, sessionID: session.identifier, prefersEventStream: eventStream)
    }

    private func receive(_ event: NativeHostConnection.Event, from hostIdentifier: String) {
        switch event {
        case .notification(let owner, let data):
            let recipients = state.withLockedValue { storage -> [NativeBrokerSession] in
                if let owner { return storage.sessions[owner].map { [$0] } ?? [] }
                return storage.sessions.values.filter { $0.state.withLockedValue { $0.usesHost(hostIdentifier) } }
            }
            for session in recipients where !session.state.withLockedValue({ $0.closed }) {
                eventSource.emit(.notification(sessionID: session.identifier, data: data))
            }
        case .processEnded(let generation):
            for session in state.withLockedValue({ Array($0.sessions.values) }) {
                session.invalidateReferences(hostIdentifier: hostIdentifier, endedGeneration: generation)
            }
            reapUnusedHosts()
        }
    }

    private func hosts() -> [NativeBrokerHost] {
        state.withLockedValue { Array($0.hosts.values) }.sorted { $0.index < $1.index }
    }

    private func descriptor(_ host: NativeBrokerHost) -> JSONValue {
        var result = host.installation.fields
        result["kind"] = .string(host.guiProcess == nil ? "headless" : "gui")
        result["hostIdentifier"] = .string(host.identifier)
        result["isDefault"] = .bool(host.identifier == Self.defaultHostIdentifier)
        let status = host.status
        let isRunning = host.guiProcess.map(inventory.isGUIProcessRunning)
        result["isReady"] = .bool(status.phase == .ready && isRunning != false)
        if let process = host.guiProcess {
            result["processIdentifier"] = .number(.int(Int64(process.processID)))
            result["isRunning"] = .bool(isRunning == true)
        }
        if case .object(let fields)? = status.origin, let version = fields["xcodeVersion"] {
            result["xcodeVersion"] = version
        }
        return .object(result)
    }

    // MARK: - Session lifetime

    package func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState {
        guard let session = state.withLockedValue({ $0.sessions[id] }) else { return .missing }
        return session.state.withLockedValue { storage in
            guard !storage.closed else { return .missing }
            storage.activity = DispatchTime.now().uptimeNanoseconds
            if let version = storage.protocolVersion { return .initialized(protocolVersion: version) }
            return .uninitialized
        }
    }

    package func clientRequestFinished(_ id: ProxySessionID) {
        guard let session = state.withLockedValue({ $0.sessions[id] }) else { return }
        session.state.withLockedValue { storage in
            storage.activeRequests -= 1
            storage.activity = DispatchTime.now().uptimeNanoseconds
        }
    }
    package func clientEventStreamOpened(_ id: ProxySessionID) -> Bool {
        guard let session = state.withLockedValue({ $0.sessions[id] }) else { return false }
        return session.state.withLockedValue { storage in
            guard !storage.closed else { return false }
            storage.eventStreams += 1
            storage.activity = DispatchTime.now().uptimeNanoseconds
            return true
        }
    }
    package func clientEventStreamClosed(_ id: ProxySessionID) {
        guard let session = state.withLockedValue({ $0.sessions[id] }) else { return }
        session.state.withLockedValue { storage in
            storage.eventStreams -= 1
            storage.activity = DispatchTime.now().uptimeNanoseconds
        }
    }
    package func expireInactiveSessions(inactiveFor: TimeAmount) {
        let now = DispatchTime.now().uptimeNanoseconds
        let expired = state.withLockedValue { storage in
            let expired = storage.sessions.values.filter { session in
                session.state.withLockedValue { value in
                    guard !value.closed, value.activeRequests == 0, value.eventStreams == 0,
                          now >= value.activity,
                          now - value.activity >= UInt64(inactiveFor.nanoseconds) else { return false }
                    value.closed = true
                    return true
                }
            }
            for session in expired { close(session, in: &storage) }
            return expired
        }
        for session in expired { eventSource.emit(.sessionClosed(sessionID: session.identifier)) }
    }
    package func removeSession(_ id: ProxySessionID) {
        let session = state.withLockedValue { storage in
            let session = storage.sessions[id]
            guard let session, session.state.withLockedValue({ state in
                guard !state.closed else { return false }
                state.closed = true
                return true
            }) else { return nil as NativeBrokerSession? }
            close(session, in: &storage)
            return session
        }
        if let session { eventSource.emit(.sessionClosed(sessionID: session.identifier)) }
    }

    private func reapUnusedHosts() {
        state.withLockedValue { reapUnusedHosts(in: &$0) }
    }

    /// Stops GUI bridges that no session references or uses. The GUI Xcode itself keeps running.
    private func reapUnusedHosts(in storage: inout State) {
        guard !storage.stopped else { return }
        let unused = storage.hosts.values.filter { host in
            guard host.guiProcess != nil, host.status.phase != .idle else { return false }
            return !storage.sessions.values.contains { $0.state.withLockedValue { $0.usesHost(host.identifier) } }
        }
        for host in unused {
            // Retiring synchronously keeps a session that pins the host next from using this process.
            let stop = host.connection.retire()
            let key = UUID()
            storage.closing[key] = Task { [self] in
                await stop.value
                _ = state.withLockedValue { $0.closing.removeValue(forKey: key) }
            }
        }
    }

    private func close(_ session: NativeBrokerSession, in storage: inout State) {
        let released = session.referencedWorkspaces()
        let key = UUID()
        storage.closing[key] = Task { [self] in
            await session.close().value
            state.withLockedValue { storage in
                if storage.sessions[session.identifier] === session {
                    storage.sessions.removeValue(forKey: session.identifier)
                }
            }
            await closeUnreferencedWorkspaces(released)
            state.withLockedValue { storage in
                reapUnusedHosts(in: &storage)
                storage.closing.removeValue(forKey: key)
            }
        }
    }

    /// Closes the headless models among `workspaces` that no session references any longer.
    private func closeUnreferencedWorkspaces(_ workspaces: [NativeBrokerWorkspace]) async {
        // Shutdown and reset stop the hosts, which close their models anyway.
        guard !state.withLockedValue({ $0.stopped || $0.resetsInProgress > 0 }) else { return }
        var seen: Set<NativeBrokerWorkspace.Scope> = []
        for workspace in workspaces where !workspace.gui && seen.insert(workspace.scope).inserted {
            guard closingWorkspaces.withLockedValue({ markClosingIfUnreferenced(workspace, closing: &$0) }) else { continue }
            if let host = state.withLockedValue({ $0.hosts[workspace.hostIdentifier] }) {
                let request = JSONValue.object([
                    "jsonrpc": .string("2.0"), "id": .string("broker-close-" + UUID().uuidString),
                    "method": .string("tools/call"),
                    "params": .object(["name": .string(Self.closeWorkspaceTool), "arguments": .object([
                        "workspaceIdentifier": .string(workspace.nativeIdentifier),
                    ])]),
                ])
                let timeout = MCP.MethodDispatcher.timeoutForMethod("tools/call", defaultSeconds: configuration.requestTimeout)
                do {
                    let reply = try await withDeadline(timeout) {
                        try await host.connection.sendToRunningProcess(request, generation: workspace.generation)
                    }
                    if let value = try? JSONRPC.Wire.resultValue(fromResponseData: reply), Self.isToolError(value) {
                        logger.notice("Could not close an unreferenced workspace", metadata: ["result": "\(value)"])
                    }
                } catch NativeHostConnectionError.expired {
                    // The process that owned the model has ended or is stopping, and the model with it.
                } catch is CancellationError {
                    // Shutdown or reset stops the host, which closes the model.
                } catch {
                    logger.notice("Could not close an unreferenced workspace", metadata: ["error": "\(error)"])
                }
            }
            _ = closingWorkspaces.withLockedValue { $0.remove(workspace.scope) }
        }
    }

    /// Runs `operation`, failing it with `CancellationError` once `timeout` elapses.
    private func withDeadline<T: Sendable>(_ timeout: TimeAmount?,
                                           _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let timeout else { return try await operation() }
        let clock = clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                await clock.sleep(.nanoseconds(timeout.nanoseconds))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Schedules `closeUnreferencedWorkspaces` as owned work that shutdown waits for.
    private func scheduleUnreferencedClose(_ workspaces: [NativeBrokerWorkspace]) {
        guard workspaces.contains(where: { !$0.gui }) else { return }
        state.withLockedValue { storage in
            let key = UUID()
            storage.closing[key] = Task { [self] in
                await closeUnreferencedWorkspaces(workspaces)
                _ = state.withLockedValue { $0.closing.removeValue(forKey: key) }
            }
        }
    }

    /// Stops waiting for model closes that stopping the hosts makes unnecessary. Session teardown
    /// in the same tasks still completes, because it awaits work the cancellation does not reach.
    private func cancelPendingCleanup() {
        for task in state.withLockedValue({ Array($0.closing.values) }) { task.cancel() }
    }

    private func waitForClosingResources() async {
        while true {
            let pending = state.withLockedValue { Array($0.closing.values) }
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    package func cancelForDeinit() {
        let resources = state.withLockedValue { storage in
            storage.stopped = true
            return (Array(storage.sessions.keys), Array(storage.hosts.values))
        }
        for id in resources.0 { removeSession(id) }
        for host in resources.1 { host.connection.cancelForDeinit() }
        eventSource.finish()
    }
    package func shutdown() async {
        let resources = state.withLockedValue { storage in
            storage.stopped = true
            return (Array(storage.sessions.keys), Array(storage.hosts.values))
        }
        for id in resources.0 { removeSession(id) }
        cancelPendingCleanup()
        await waitForClosingResources()
        await withTaskGroup(of: Void.self) { group in
            for host in resources.1 { group.addTask { await host.connection.shutdown() } }
        }
        eventSource.finish()
    }
    package func snapshot() -> ProxyRuntimeSnapshot {
        let upstreams = hosts().compactMap { host -> ProxyRuntimeSnapshot.Upstream? in
            let status = host.status
            guard status.phase != .idle else { return nil }
            return .init(id: host.index, healthState: status.phase == .ready ? "healthy" : status.phase.rawValue,
                         isInitialized: status.phase == .ready, activeRequestCount: status.inFlightRequests)
        }
        return .init(generatedAt: Date(), proxyInitialized: true, catalogAvailable: true,
                     queuedRequestCount: 0, upstreams: upstreams)
    }
    package func debugSnapshotData(includeSensitivePayloads: Bool) -> Data? {
        let values = hosts().map { host -> [String: Any] in
            let status = host.status
            var result: [String: Any] = [
                "hostIdentifier": host.identifier,
                "developerDirectory": host.installation.developerDirectory.path,
                "kind": host.guiProcess == nil ? "headless" : "gui",
                "phase": status.phase.rawValue,
                "inFlightRequests": status.inFlightRequests,
            ]
            if let generation = status.runningGeneration { result["generation"] = generation }
            if let origin = status.origin { result["origin"] = origin.foundationObject }
            return result
        }
        return try? JSONSerialization.data(withJSONObject: ["hosts": values], options: [.sortedKeys])
    }
    package func reset() async {
        let sessions = state.withLockedValue { storage in
            storage.resetsInProgress += 1
            return Array(storage.sessions.keys)
        }
        for id in sessions { removeSession(id) }
        cancelPendingCleanup()
        await waitForClosingResources()
        for host in hosts() { await host.connection.stopProcess() }
        state.withLockedValue { storage in
            storage.publicCatalog = nil
            storage.resetsInProgress -= 1
        }
        start()
    }
}

private extension NativeHostBroker {
    private func callTool(_ request: ProxyRuntimeRequest, session: NativeBrokerSession,
                          admission: Admission) async throws -> ProxyRuntimeReply {
        guard case .object(let object)? = request.decodedJSON,
              case .object(let parameters)? = object["params"],
              case .string(let name)? = parameters["name"] else {
            throw NativeHostBrokerError("tools/call requires a tool name")
        }
        let arguments: [String: JSONValue]
        if case .object(let values)? = parameters["arguments"] { arguments = values }
        else { arguments = [:] }
        let result: JSONValue
        switch name {
        case Self.listTool:
            for installation in try await inventory.discover() { _ = try register(installation: installation) }
            try discoverGUIHosts()
            result = try Self.toolResult(.object(["hosts": .array(hosts().filter { host in
                host.guiProcess.map(inventory.isGUIProcessRunning) ?? true
            }.map(descriptor))]))
        case Self.listWorkspacesTool:
            result = try await listWorkspaces(request, session: session)
        case Self.openWorkspaceTool:
            result = try await openWorkspace(arguments, request: request, session: session)
        case Self.closeWorkspaceTool:
            guard let workspace = admission.workspace else {
                throw NativeHostBrokerError("XcodeCloseWorkspace requires a workspaceIdentifier returned by XcodeOpenWorkspace or XcodeListWorkspaces")
            }
            guard let host = state.withLockedValue({ $0.hosts[workspace.hostIdentifier] }) else {
                throw NativeHostBrokerError("The workspace's Xcode host is unavailable")
            }
            guard try await runningGeneration(of: host) == workspace.generation else { throw Self.expiredReference() }
            if workspace.gui {
                _ = session.state.withLockedValue { $0.workspaces.removeValue(forKey: workspace.identifier) }
                result = try Self.toolResult(.object([
                    "workspaceIdentifier": .string(workspace.identifier), "released": .bool(true),
                    "message": .string("Released the workspace reference. The Xcode window remains open."),
                ]))
            } else if !electNativeClose(of: workspace, in: session) {
                result = try Self.toolResult(.object([
                    "workspaceIdentifier": .string(workspace.identifier), "released": .bool(true),
                    "message": .string("Released this session's reference. Another session still uses the workspace, so it remains open."),
                ]))
            } else {
                let native = try Self.toolRequest(request, name: name,
                    arguments: ["workspaceIdentifier": .string(workspace.nativeIdentifier)])
                let reply: ProxyRuntimeReply
                let closed: Bool
                do {
                    reply = try Self.externalReply(
                        await send(native, to: host, session: session, generation: workspace.generation,
                                   eventStream: request.prefersEventStream),
                        session: session.identifier, hostIdentifier: workspace.hostIdentifier)
                    closed = !Self.isToolError(try Self.result(in: reply))
                } catch {
                    finishNativeClose(of: workspace, in: session, host: host, closed: false)
                    throw error
                }
                finishNativeClose(of: workspace, in: session, host: host, closed: closed)
                return try Self.rewriteReply(reply, workspace: workspace, deviceSession: nil)
            }
        default:
            return try await callNativeTool(name, arguments: arguments, request: request,
                session: session, admission: admission)
        }
        return try Self.response(id: Self.requestID(request), result: result, session: session.identifier,
                                 eventStream: request.prefersEventStream)
    }

    /// Removes the session's handle and reports whether this call must close the native model:
    /// the handle was still bound, nothing else references the model, and no close is in flight.
    private func electNativeClose(of workspace: NativeBrokerWorkspace, in session: NativeBrokerSession) -> Bool {
        closingWorkspaces.withLockedValue { closing in
            let removed = session.state.withLockedValue { $0.workspaces.removeValue(forKey: workspace.identifier) } != nil
            return removed && markClosingIfUnreferenced(workspace, closing: &closing)
        }
    }

    /// Marks the model as closing when no handle, device session, or launch session in any session
    /// references it. Called under the `closingWorkspaces` lock, which binding also takes.
    private func markClosingIfUnreferenced(_ workspace: NativeBrokerWorkspace,
                                           closing: inout Set<NativeBrokerWorkspace.Scope>) -> Bool {
        let sessions = state.withLockedValue { Array($0.sessions.values) }
        guard !closing.contains(workspace.scope),
              !sessions.contains(where: { $0.retainsNativeWorkspace(workspace) }) else { return false }
        closing.insert(workspace.scope)
        return true
    }

    private func finishNativeClose(of workspace: NativeBrokerWorkspace, in session: NativeBrokerSession,
                                   host: NativeBrokerHost, closed: Bool) {
        closingWorkspaces.withLockedValue { closing in
            if !closed { session.restoreWorkspace(workspace, host: host) }
            closing.remove(workspace.scope)
        }
    }

    /// Binds a handle unless its native model is being closed; a model mid-close is about to disappear.
    private func bindWorkspace(in session: NativeBrokerSession, host: NativeBrokerHost, generation: UInt64,
                               nativeIdentifier: String, path: String?, name: String?) throws -> NativeBrokerWorkspace {
        try closingWorkspaces.withLockedValue { closing in
            let scope = NativeBrokerWorkspace.Scope(hostIdentifier: host.identifier, generation: generation,
                                                    nativeIdentifier: nativeIdentifier)
            guard !closing.contains(scope) else { throw NativeBrokerWorkspaceClosing() }
            return try session.bindWorkspace(host: host, generation: generation, nativeIdentifier: nativeIdentifier,
                                             path: path, name: name)
        }
    }

    private func discoverGUIHosts() throws {
        for process in inventory.runningGUIProcesses() {
            _ = try register(installation: process.installation, guiProcess: process)
        }
    }

    /// Keeps a reclaimable host in use while `operation` runs.
    private func withPinnedHost<T: Sendable>(_ host: NativeBrokerHost, session: NativeBrokerSession,
                                             operation: () async throws -> T) async throws -> T {
        try session.state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            state.hostRequests[host.identifier, default: 0] += 1
        }
        defer { session.releaseHost(host.identifier); reapUnusedHosts() }
        return try await operation()
    }

    private func listWorkspaces(_ request: ProxyRuntimeRequest, session: NativeBrokerSession) async throws -> JSONValue {
        try discoverGUIHosts()
        let targets = hosts().filter {
            if let gui = $0.guiProcess { return inventory.isGUIProcessRunning(gui) }
            return $0.identifier == Self.defaultHostIdentifier || $0.status.phase == .ready
        }
        var entries: [JSONValue] = []
        var errors: [JSONValue] = []
        for host in targets {
            do {
                let listed = try await withPinnedHost(host, session: session) {
                    let generation = try await runningGeneration(of: host)
                    let entries = try await workspaceEntries(host: host, generation: generation, request: request,
                                                             session: session)
                    return try entries.compactMap { entry -> NativeBrokerWorkspace? in
                        do {
                            return try bindWorkspace(in: session, host: host, generation: generation,
                                                     nativeIdentifier: entry.nativeIdentifier, path: entry.path, name: nil)
                        } catch is NativeBrokerWorkspaceClosing { return nil }
                    }
                }
                entries.append(contentsOf: listed.map(\.descriptor))
            } catch is CancellationError { throw CancellationError() }
            catch let error as NativeHostBrokerReplyError {
                var detail: [String: JSONValue] = ["hostIdentifier": .string(host.identifier)]
                switch error.reply {
                case .failure(let kind, let message, _):
                    detail["failureKind"] = .string(String(describing: kind))
                    detail["message"] = .string(message)
                case .mcpError(_, let code, let message, _, _):
                    detail["error"] = .object(["code": .number(.int(Int64(code))), "message": .string(message)])
                case .response(let data, _, _):
                    let object = try JSONRPC.Wire.object(fromData: data)
                    detail["error"] = object["error"].flatMap(JSONValue.init(any:))
                case .accepted:
                    detail["message"] = .string(error.description)
                }
                errors.append(.object(detail))
            }
            catch let error as NativeBrokerToolFailure {
                errors.append(.object(["hostIdentifier": .string(host.identifier), "error": error.result]))
            } catch {
                errors.append(.object(["hostIdentifier": .string(host.identifier),
                                       "message": .string(String(describing: error))]))
            }
        }
        var payload: [String: JSONValue] = ["workspaces": .array(entries)]
        if !errors.isEmpty { payload["errors"] = .array(errors) }
        return try Self.toolResult(.object(payload), isError: !errors.isEmpty)
    }

    private func workspaceEntries(host: NativeBrokerHost, generation: UInt64, request: ProxyRuntimeRequest,
                                  session: NativeBrokerSession) async throws -> [NativeBrokerWorkspaceEntry] {
        let gui = host.guiProcess != nil
        let native = try Self.toolRequest(request, name: gui ? "XcodeListWindows" : Self.listWorkspacesTool,
                                         arguments: [:])
        let value = try Self.result(in: await send(native, to: host, session: session, generation: generation,
                                                   eventStream: request.prefersEventStream))
        if Self.isToolError(value) { throw NativeBrokerToolFailure(result: value) }
        let payload = try Self.toolPayload(value)
        guard let message = Self.string(payload["message"]) else {
            throw NativeHostBrokerError("Native workspace enumeration returned no message")
        }
        let selector = gui ? "tabIdentifier: " : "workspaceIdentifier: "
        return try message.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: selector) else { return nil }
            let entry = line[marker.upperBound...]
            guard let separator = entry.range(of: ", workspacePath: ") else {
                throw NativeHostBrokerError("Native workspace enumeration has no workspacePath: \(line)")
            }
            let identifier = String(entry[..<separator.lowerBound])
            let path = String(entry[separator.upperBound...])
            return NativeBrokerWorkspaceEntry(nativeIdentifier: identifier, path: path)
        }
    }

    private func openWorkspace(_ arguments: [String: JSONValue], request: ProxyRuntimeRequest,
                               session: NativeBrokerSession) async throws -> JSONValue {
        guard let path = Self.string(arguments["path"]) else {
            throw NativeHostBrokerError("XcodeOpenWorkspace requires path")
        }
        let hostIdentifier = Self.string(arguments["hostIdentifier"]) ?? Self.defaultHostIdentifier
        guard let host = state.withLockedValue({ $0.hosts[hostIdentifier] }) else {
            throw NativeHostBrokerError("Unknown hostIdentifier; call XcodeMCPKitListHosts")
        }
        return try await withPinnedHost(host, session: session) {
            let generation = try await runningGeneration(of: host)
            if host.guiProcess != nil {
                let entries = try await workspaceEntries(host: host, generation: generation, request: request,
                                                         session: session)
                let normalized = Self.normalizedWorkspacePath(path)
                let matches = entries.filter {
                    Self.normalizedWorkspacePath($0.path) == normalized
                }
                guard matches.count == 1, let entry = matches.first else {
                    if matches.isEmpty {
                        throw NativeHostBrokerError("The GUI host has no open window for this path. Open it in Xcode, or omit hostIdentifier to open a headless workspace.")
                    }
                    throw NativeHostBrokerError("Several Xcode windows have this path. Call XcodeListWorkspaces and choose the intended window's workspaceIdentifier.")
                }
                let workspace = try bindWorkspace(in: session, host: host, generation: generation,
                                                  nativeIdentifier: entry.nativeIdentifier, path: entry.path, name: nil)
                return try Self.toolResult(workspace.descriptor)
            }
            let native = try Self.toolRequest(request, name: Self.openWorkspaceTool,
                                             arguments: ["path": .string(path)])
            let value = try Self.result(in: await send(native, to: host, session: session, generation: generation,
                                                       eventStream: request.prefersEventStream))
            if Self.isToolError(value) { return value }
            let payload = try Self.toolPayload(value)
            guard let identifier = Self.string(payload["workspaceIdentifier"]) else {
                throw NativeHostBrokerError("Native XcodeOpenWorkspace returned no workspaceIdentifier")
            }
            let workspace = try bindWorkspace(in: session, host: host, generation: generation, nativeIdentifier: identifier,
                path: Self.string(payload["workspacePath"]) ?? path, name: Self.string(payload["name"]))
            return try Self.toolResult(Self.rewritePayload(.object(payload), workspace: workspace, deviceSession: nil))
        }
    }

    private static func normalizedWorkspacePath(_ path: String) -> String {
        var url = URL(filePath: path).standardizedFileURL
        if url.lastPathComponent == "Package.swift",
           (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            url.deleteLastPathComponent()
        }
        return url.resolvingSymlinksInPath().path
    }

    private static func expiredReference() -> NativeHostBrokerError {
        NativeHostBrokerError(NativeHostConnectionError.expired.description)
    }

    private static func workspaceConflict(_ workspace: NativeBrokerWorkspace,
        device: NativeBrokerDeviceSession?, launch: NativeBrokerLaunchSession?) -> String? {
        if let device, workspace.hostIdentifier != device.hostIdentifier || workspace.generation != device.generation
            || device.workspace.map({ !workspace.hasSameNativeScope(as: $0) }) == true {
            return "The workspace and device session belong to different execution contexts"
        }
        if let launch, workspace.hostIdentifier != launch.hostIdentifier || workspace.generation != launch.generation
            || launch.workspace.map({ !workspace.hasSameNativeScope(as: $0) }) == true {
            return "The workspace and launch session belong to different execution contexts"
        }
        return nil
    }

    private func callNativeTool(_ name: String, arguments: [String: JSONValue], request: ProxyRuntimeRequest,
                                session: NativeBrokerSession, admission: Admission) async throws -> ProxyRuntimeReply {
        guard let host = state.withLockedValue({ $0.hosts[admission.hostIdentifier] }) else {
            throw NativeHostBrokerError("The workspace's Xcode host is unavailable")
        }
        var workspace = admission.workspace
        if let selector = Self.string(arguments["workspaceIdentifier"]), selector.hasPrefix("/") {
            if admission.deviceSession != nil || admission.launchSession != nil {
                guard let parent = admission.deviceSession?.workspace ?? admission.launchSession?.workspace,
                      let path = parent.path else {
                    throw NativeHostBrokerError("This session has no workspace path. Use an existing workspaceIdentifier, or omit it to keep the session's workspace.")
                }
                guard parent.hostIdentifier == Self.defaultHostIdentifier,
                      Self.normalizedWorkspacePath(selector) == Self.normalizedWorkspacePath(path) else {
                    throw NativeHostBrokerError("The workspace path and session belong to different execution contexts. Use a matching workspaceIdentifier, or omit it to keep the session's workspace.")
                }
                if let conflict = Self.workspaceConflict(parent,
                    device: admission.deviceSession, launch: admission.launchSession) {
                    throw NativeHostBrokerError(conflict)
                }
                workspace = parent
            } else {
                let opened = try await openWorkspace(["path": .string(selector)], request: request, session: session)
                if Self.isToolError(opened) {
                    return try Self.response(id: Self.requestID(request), result: opened,
                        session: session.identifier, eventStream: request.prefersEventStream)
                }
                let payload = try Self.toolPayload(opened)
                workspace = Self.string(payload["workspaceIdentifier"]).flatMap { identifier in
                    session.state.withLockedValue { $0.workspaces[identifier] }
                }
            }
        }
        if let workspace, workspace.hostIdentifier != host.identifier {
            throw NativeHostBrokerError("The workspace path resolves on the default host, while the session belongs to another host. Use a workspaceIdentifier from the same host.")
        }
        let generation = try await runningGeneration(of: host)
        guard [workspace?.generation, admission.deviceSession?.generation, admission.launchSession?.generation]
            .compactMap({ $0 }).allSatisfy({ $0 == generation }) else {
            throw Self.expiredReference()
        }
        var nativeArguments = arguments
        nativeArguments.removeValue(forKey: "hostIdentifier")
        if let workspace {
            nativeArguments.removeValue(forKey: "workspaceIdentifier")
            nativeArguments[workspace.gui ? "tabIdentifier" : "workspaceIdentifier"] = .string(workspace.nativeIdentifier)
        }
        if let device = admission.deviceSession {
            nativeArguments["interactionSessionKey"] = .string(device.nativeIdentifier)
        }
        if let launch = admission.launchSession {
            nativeArguments["launchSessionReference"] = .string(launch.nativeIdentifier)
        }
        let catalog = try await nativeCatalog(of: host)
        guard catalog.generation == generation else { throw Self.expiredReference() }
        let native = try XcodeToolCatalog.nativeCall(name: name, arguments: nativeArguments,
            nativeCatalog: catalog.result)
        let forwarded = try Self.toolRequest(request, name: native.name, arguments: native.arguments)
        var reply = try await send(forwarded, to: host, session: session, generation: generation,
                                   eventStream: request.prefersEventStream)
        if case .response(let data, let replySession, let stream) = reply {
            reply = .response(data: ToolCallNormalizer().normalizeResponseDataIfNeeded(
                method: "tools/call", toolName: native.name, toolsCatalogOverride: catalog.result, upstreamData: data),
                sessionID: replySession, prefersEventStream: stream)
        }
        let value = try Self.result(in: reply)
        if Self.isToolError(value) {
            return try Self.externalReply(reply, session: session.identifier, hostIdentifier: host.identifier)
        }
        var device = admission.deviceSession
        var launch = admission.launchSession
        if name == "RunProject" {
            let payload = try Self.toolPayload(value)
            if let nativeID = Self.string(payload["launchSessionReference"]) {
                launch = try session.bindLaunchSession(host: host, generation: generation, nativeIdentifier: nativeID,
                                                       workspace: workspace)
            }
        }
        if name == "DeviceInteractionStartSession" {
            let payload = try Self.toolPayload(value)
            guard let nativeID = Self.string(payload["interactionSessionKey"]) ?? Self.string(payload["interactSessionKey"]) else {
                throw NativeHostBrokerError("Native device interaction returned no session key")
            }
            device = try session.bindDeviceSession(host: host, generation: generation, nativeIdentifier: nativeID,
                                                   workspace: workspace)
        }
        if name == "DeviceInteractionEndSession", let device {
            _ = session.state.withLockedValue { $0.deviceSessions.removeValue(forKey: device.identifier) }
            scheduleUnreferencedClose(device.workspace.map { [$0] } ?? [])
        }
        if workspace == nil, name == "XcodeNewProject" {
            let payload = try Self.toolPayload(value)
            if let nativeID = Self.string(payload["workspaceIdentifier"]) {
                workspace = try bindWorkspace(in: session, host: host, generation: generation, nativeIdentifier: nativeID,
                    path: Self.string(payload["workspacePath"]), name: nil)
            }
        }
        return try Self.externalReply(Self.rewriteReply(reply, workspace: name == "XcodeNewProject" ? workspace : nil,
                deviceSession: name == "DeviceInteractionStartSession" ? device : nil,
                launchSession: ["RunProject", "GetConsoleOutput"].contains(name) ? launch : nil, toolName: name),
                                      session: session.identifier, hostIdentifier: host.identifier)
    }
}

private struct NativeBrokerToolFailure: Error {
    let result: JSONValue
}

private struct NativeBrokerWorkspaceClosing: Error, CustomStringConvertible {
    var description: String { "The workspace is being closed. Open it again with XcodeOpenWorkspace." }
}
