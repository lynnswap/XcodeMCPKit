import Foundation
import NIOCore
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

package final class NativeHostBroker: ProxyRuntimeServing, Sendable {
    typealias RuntimeFactory = @Sendable (ProxyRuntimeConfiguration) throws -> any ProxyRuntimeServing

    private struct Binding: Sendable {
        let session: NativeBrokerSession
        let hostIdentifier: String
    }
    private struct State: Sendable {
        var hosts: [String: NativeBrokerHost] = [:]
        var installations: [URL: String] = [:]
        var guiProcesses: [XcodeGUIProcess.Identity: String] = [:]
        var sessions: [ProxySessionID: NativeBrokerSession] = [:]
        var backendBindings: [ProxySessionID: Binding] = [:]
        var closing: [UUID: Task<Void, Never>] = [:]
        /// Headless models whose native close is in flight; new handles to them are refused.
        var closingWorkspaces: Set<NativeBrokerWorkspace.Scope> = []
        var stopped = false
        var resetsInProgress = 0
        var publicCatalog: JSONValue?
    }
    private let state = NIOLockedValueBox(State())
    private let eventSource = ProxyRuntimeEventSource()
    private let configuration: ProxyRuntimeConfiguration
    private let inventory: XcodeHostInventory
    private let factory: RuntimeFactory
    private let clock: ClockClient
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
    }

    package convenience init(configuration: ProxyRuntimeConfiguration) throws {
        try self.init(configuration: configuration,
                      inventory: XcodeHostInventory.live(configuration: configuration)) {
            ProxyRuntime(configuration: $0)
        }
    }

    init(configuration: ProxyRuntimeConfiguration, inventory: XcodeHostInventory,
         clock: ClockClient = .liveValue, factory: @escaping RuntimeFactory) throws {
        self.configuration = configuration
        self.inventory = inventory
        self.factory = factory
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
            var config = configuration
            config.developerDirectoryURL = installation.developerDirectory
            config.guiProcess = guiProcess
            let frozenConfig = config
            let host = NativeBrokerHost(identifier: id, index: (storage.hosts.values.map(\.index).max() ?? -1) + 1,
                installation: installation, guiProcess: guiProcess, create: { [factory] in try factory(frozenConfig) },
                receive: { [weak self] event in self?.receive(event, from: id) })
            storage.hosts[id] = host
            if let guiProcess { storage.guiProcesses[guiProcess.identity] = id }
            else { storage.installations[installation.developerDirectory] = id }
            return host
        }
    }

    package func start() {
        if let host = state.withLockedValue({ $0.hosts[Self.defaultHostIdentifier] }) {
            Task { _ = try? await host.activate() }
        }
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
            return NativeHostBrokerOperation(cancelledReply: cancelled) { _ in
                .mcpError(id: requestID, code: -32600, message: "invalid request",
                          sessionID: nil, prefersEventStream: stream)
            }
        }
        let creates = !message.headerSessionExists
        if creates {
            guard let object, case .request("initialize", _) = JSONRPC.Message.Inspector.kind(of: object),
                  !state.withLockedValue({ $0.stopped || $0.resetsInProgress > 0 }) else { return nil }
            let parameters: JSONValue
            if case .object(let values)? = message.decodedJSON {
                parameters = values["params"] ?? .object([:])
            } else { parameters = .object([:]) }
            let session = NativeBrokerSession(identifier: sessionID, initializeParameters: parameters)
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
            return Admission(hostIdentifier: host, workspace: workspace, deviceSession: device, launchSession: launch, error: error)
        }
        guard let admission else { return nil }
        let key = UUID()
        let admittedMessage = message
        let timeoutReply = ProxyRuntimeReply.mcpError(id: requestID, code: -32000,
            message: "upstream timeout", sessionID: sessionID, prefersEventStream: message.prefersEventStream)
        let operation = NativeHostBrokerOperation(cancelledReply: cancelled, requestIDKey: requestID?.key,
            deadline: message.deadline, clock: clock, timeoutReply: timeoutReply) { [self] cancellation in
            let reply = await process(admittedMessage, in: session, admission: admission, cancellation: cancellation)
            session.releaseHost(admission.hostIdentifier)
            closeUnusedChannels(in: session)
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
                         admission: Admission,
                         cancellation: NativeHostBrokerCancellation) async -> ProxyRuntimeReply {
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
            case .notification("notifications/initialized"):
                return .accepted(sessionID: session.identifier)
            case .notification("notifications/cancelled"):
                if let parameters = object["params"] as? [String: Any],
                   let cancelledID = Self.cancellationID(from: parameters["requestId"]) {
                    let operations = session.state.withLockedValue { Array($0.operations.values) }
                    for operation in operations where operation.requestIDKey == cancelledID.key {
                        operation.cancel(reason: .clientNotification)
                    }
                }
                return .accepted(sessionID: session.identifier)
            case .response(let responseID):
                return try await forwardServerResponse(json, id: responseID, session: session,
                                                       cancellation: cancellation)
            case .request("ping", _):
                return try Self.response(id: id, result: .object([:]), session: session.identifier,
                                         eventStream: request.prefersEventStream)
            case .request("tools/list", _):
                if (object["params"] as? [String: Any])?["cursor"] != nil {
                    return .mcpError(id: id, code: -32602, message: "Invalid tools/list cursor",
                        sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
                }
                if let catalog = state.withLockedValue({ $0.publicCatalog }) {
                    return try Self.response(id: id, result: catalog, session: session.identifier,
                                             eventStream: request.prefersEventStream)
                }
                let reply = try await forward(request, session: session,
                    hostIdentifier: Self.defaultHostIdentifier, cancellation: cancellation)
                let catalog = try XcodeToolCatalog.publicResult(from: Self.result(in: reply),
                                                              managementTools: Self.managementTools)
                let published = state.withLockedValue { storage in
                    if storage.publicCatalog == nil { storage.publicCatalog = catalog }
                    return storage.publicCatalog ?? catalog
                }
                return try Self.response(id: id, result: published, session: session.identifier,
                                         eventStream: request.prefersEventStream)
            case .request("tools/call", _):
                if let arguments = (object["params"] as? [String: Any])?["arguments"],
                   !(arguments is [String: Any]) {
                    return .mcpError(id: id, code: -32602, message: "tools/call arguments must be an object",
                        sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
                }
                do {
                    if let error = admission.error { throw NativeHostBrokerError(error) }
                    return try await callTool(request, session: session, admission: admission,
                                              cancellation: cancellation)
                } catch let error as NativeHostBrokerReplyError {
                    return try Self.externalReply(error.reply, session: session.identifier, requestID: id)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return try Self.response(id: id, result: Self.toolResult(.object([
                        "message": .string(String(describing: error)),
                    ]), isError: true), session: session.identifier, eventStream: request.prefersEventStream)
                }
            case .request, .notification, .other:
                return try await forward(request, session: session,
                                         hostIdentifier: admission.hostIdentifier, cancellation: cancellation)
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

    private func channel(for host: NativeBrokerHost, session: NativeBrokerSession)
        async throws -> NativeBrokerChannel {
        if let process = host.guiProcess, !inventory.isGUIProcessRunning(process) {
            throw NativeHostBrokerError("The workspace's Xcode process is no longer running")
        }
        let channel = try await session.channel(for: host, register: { [self] backendID in
            try state.withLockedValue { storage in
                guard storage.sessions[session.identifier] === session, !storage.stopped else {
                    throw CancellationError()
                }
                storage.backendBindings[backendID] = Binding(session: session, hostIdentifier: host.identifier)
            }
        }, unregister: { [self] backendID in
            _ = state.withLockedValue { $0.backendBindings.removeValue(forKey: backendID) }
        })
        if let process = host.guiProcess, !inventory.isGUIProcessRunning(process) {
            channel.close()
            throw NativeHostBrokerError("The workspace's Xcode process exited while connecting")
        }
        return channel
    }

    private func forward(_ request: ProxyRuntimeRequest, session: NativeBrokerSession,
                         hostIdentifier: String, cancellation: NativeHostBrokerCancellation)
        async throws -> ProxyRuntimeReply {
        guard let host = state.withLockedValue({ $0.hosts[hostIdentifier] }) else {
            throw NativeHostBrokerError("The workspace's Xcode host is unavailable")
        }
        let channel = try await channel(for: host, session: session)
        try Task.checkCancellation()
        let reply = try await channel.execute(request, cancellation: cancellation)
        return try Self.externalReply(reply, session: session.identifier, hostIdentifier: hostIdentifier)
    }

    private func forwardServerResponse(_ json: JSONValue, id: JSONRPC.ID,
                                       session: NativeBrokerSession,
                                       cancellation: NativeHostBrokerCancellation) async throws -> ProxyRuntimeReply {
        guard case .string(let externalID) = id.value,
              let range = externalID.range(of: ":"),
              let data = Data(base64Encoded: String(externalID[range.upperBound...])),
              let nativeID = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                .flatMap(JSONValue.init(any:)) else {
            throw NativeHostBrokerError("Unknown server request identifier")
        }
        let channelIdentifier = String(externalID[..<range.lowerBound])
        guard !channelIdentifier.isEmpty else { throw NativeHostBrokerError("Unknown server request identifier") }
        let backendID = ProxySessionID(rawValue: channelIdentifier)
        guard let binding = state.withLockedValue({ $0.backendBindings[backendID] }),
              binding.session === session,
              let host = state.withLockedValue({ storage -> NativeBrokerHost? in
                  guard let host = storage.hosts[binding.hostIdentifier] else { return nil }
                  session.state.withLockedValue { $0.hostRequests[host.identifier, default: 0] += 1 }
                  return host
              }) else {
            throw NativeHostBrokerError("Server request belongs to another session")
        }
        defer { session.releaseHost(host.identifier); closeUnusedChannels(in: session) }
        let channel = try await channel(for: host, session: session)
        guard channel.sessionID == backendID else {
            throw NativeHostBrokerError("The server request's original channel has closed")
        }
        guard case .object(var object) = json else { throw NativeHostBrokerError("Invalid response") }
        object["id"] = nativeID
        let request = try ProxyRuntimeRequest(json: .object(object), headerSessionExists: true,
                                             prefersEventStream: false)
        return try Self.externalReply(try await channel.execute(request, cancellation: cancellation),
                                  session: session.identifier)
    }

    private func receive(_ event: ProxyRuntimeEvent, from hostIdentifier: String) {
        if case .catalogChanged = event {
            let (host, sessions) = state.withLockedValue {
                ($0.hosts[hostIdentifier], Array($0.sessions.values))
            }
            guard let snapshot = host?.snapshot else { return }
            for session in sessions where session.invalidateReferences(
                hostIdentifier: hostIdentifier, supersededBy: snapshot.upstreamSource) {
                closeUnusedChannels(in: session)
            }
            return
        }
        guard case .notification(let backendID, let data) = event,
              let binding = state.withLockedValue({ $0.backendBindings[backendID] }),
              !binding.session.state.withLockedValue({ $0.closed }) else { return }
        do {
            var object = try JSONRPC.Wire.object(fromData: data)
            if object["method"] as? String == "notifications/tools/list_changed" { return }
            if case .request(_, let id) = JSONRPC.Message.Inspector.kind(of: object) {
                let value = try JSONSerialization.data(withJSONObject: id.value.foundationObject,
                                                       options: [.fragmentsAllowed])
                object["id"] = backendID.rawValue + ":" + value.base64EncodedString()
            }
            eventSource.emit(.notification(sessionID: binding.session.identifier,
                data: try JSONRPC.Wire.data(from: object)))
        } catch {
            eventSource.emit(.notification(sessionID: binding.session.identifier, data: data))
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
        let snapshot = host.snapshot
        let isRunning = host.guiProcess.map(inventory.isGUIProcessRunning)
        result["isReady"] = .bool(snapshot?.catalogAvailable == true && isRunning != false)
        if let process = host.guiProcess {
            result["processIdentifier"] = .number(.int(Int64(process.processID)))
            result["isRunning"] = .bool(isRunning == true)
        }
        if let origin = snapshot?.originMetadata {
            if case .object(let fields) = origin {
                if let version = fields["xcodeVersion"] { result["xcodeVersion"] = version }
            }
        }
        return .object(result)
    }

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
            for session in expired {
                storage.backendBindings = storage.backendBindings.filter { $0.value.session !== session }
                close(session, in: &storage)
            }
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
            storage.backendBindings = storage.backendBindings.filter { $0.value.session !== session }
            close(session, in: &storage)
            return session
        }
        if let session { eventSource.emit(.sessionClosed(sessionID: session.identifier)) }
    }

    private func closeUnusedChannels(in session: NativeBrokerSession) {
        session.closeUnusedChannels { [weak self] backendID in
            guard let self else { return }
            if let backendID {
                _ = state.withLockedValue { $0.backendBindings.removeValue(forKey: backendID) }
            }
            reapUnusedHosts()
        }
        reapUnusedHosts()
    }

    private func reapUnusedHosts() {
        state.withLockedValue { reapUnusedHosts(in: &$0) }
    }

    private func reapUnusedHosts(in storage: inout State) {
        guard !storage.stopped else { return }
        let unused = storage.hosts.values.filter { host in
            guard host.guiProcess != nil else { return false }
            return !storage.sessions.values.contains { session in
                session.state.withLockedValue { session in
                    (!session.closed && session.retainsHost(host.identifier))
                        || session.hostRequests[host.identifier] != nil
                        || session.channels[host.identifier] != nil
                }
            }
        }
        for host in unused {
            guard let shutdown = host.deactivate() else { continue }
            let key = UUID()
            storage.closing[key] = Task { [self] in
                await shutdown.value
                _ = state.withLockedValue { $0.closing.removeValue(forKey: key) }
            }
        }
    }

    private func close(_ session: NativeBrokerSession, in storage: inout State) {
        let key = UUID()
        storage.closing[key] = Task { [self] in
            await session.close().value
            state.withLockedValue { storage in
                if storage.sessions[session.identifier] === session {
                    storage.sessions.removeValue(forKey: session.identifier)
                }
                reapUnusedHosts(in: &storage)
                storage.closing.removeValue(forKey: key)
            }
        }
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
        for host in resources.1 { host.cancel() }
        eventSource.finish()
    }
    package func shutdown() async {
        let resources = state.withLockedValue { storage in
            storage.stopped = true
            return (Array(storage.sessions.keys), Array(storage.hosts.values))
        }
        for id in resources.0 { removeSession(id) }
        await waitForClosingResources()
        await withTaskGroup(of: Void.self) { group in
            for host in resources.1 { group.addTask { await host.shutdown() } }
        }
        eventSource.finish()
    }
    package func snapshot() -> ProxyRuntimeSnapshot {
        let snapshots = hosts().compactMap { host -> ProxyRuntimeSnapshot.Upstream? in
            guard let snapshot = host.snapshot else { return nil }
            return .init(id: host.index, healthState: snapshot.upstreams.first?.healthState ?? "unavailable",
                isInitialized: snapshot.proxyInitialized,
                activeRequestCount: snapshot.upstreams.reduce(0) { $0 + $1.activeRequestCount })
        }
        return .init(generatedAt: Date(), proxyInitialized: true, catalogAvailable: true,
            queuedRequestCount: hosts().compactMap(\.snapshot).reduce(0) { $0 + $1.queuedRequestCount },
            upstreams: snapshots)
    }
    package func debugSnapshotData(includeSensitivePayloads: Bool) -> Data? {
        let values = hosts().map { host -> [String: Any] in
            var result: [String: Any] = ["hostIdentifier": host.identifier,
                                        "developerDirectory": host.installation.developerDirectory.path]
            if let snapshot = host.snapshot { result["isInitialized"] = snapshot.proxyInitialized }
            if let data = host.runtimeIfStarted?.debugSnapshotData(
                includeSensitivePayloads: includeSensitivePayloads
            ) {
                result["runtime"] = try? JSONSerialization.jsonObject(with: data)
            }
            return result
        }
        return try? JSONSerialization.data(withJSONObject: ["hosts": values], options: [.sortedKeys])
    }
    package func reset() async {
        let sessions = state.withLockedValue { storage in
            storage.resetsInProgress += 1
            return Array(storage.sessions.keys)
        }
        defer { state.withLockedValue { $0.resetsInProgress -= 1 } }
        for id in sessions { removeSession(id) }
        await waitForClosingResources()
        for host in hosts() { if let runtime = host.runtimeIfStarted { await runtime.reset() } }
    }
}

private extension NativeHostBroker {
    private func callTool(_ request: ProxyRuntimeRequest, session: NativeBrokerSession,
                  admission: Admission, cancellation: NativeHostBrokerCancellation) async throws -> ProxyRuntimeReply {
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
            result = try await listWorkspaces(request, session: session, cancellation: cancellation)
        case Self.openWorkspaceTool:
            result = try await openWorkspace(arguments, request: request, session: session,
                                             cancellation: cancellation)
        case Self.closeWorkspaceTool:
            guard let workspace = admission.workspace else {
                throw NativeHostBrokerError("XcodeCloseWorkspace requires a workspaceIdentifier returned by XcodeOpenWorkspace or XcodeListWorkspaces")
            }
            guard let host = state.withLockedValue({ $0.hosts[workspace.hostIdentifier] }) else {
                throw NativeHostBrokerError("The workspace's Xcode host is unavailable")
            }
            let channel = try await channel(for: host, session: session)
            let source = try channel.source()
            guard source == workspace.source else { throw Self.expiredReference() }
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
                        await channel.execute(native, source: source, cancellation: cancellation),
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
                session: session, admission: admission, cancellation: cancellation)
        }
        return try Self.response(id: Self.requestID(request), result: result, session: session.identifier,
                                 eventStream: request.prefersEventStream)
    }

    /// Removes the session's handle and reports whether this call must close the native model:
    /// the handle was still bound, no other session uses the model, and no close is in flight.
    /// The decision and the in-flight mark share the broker lock, which `bindWorkspace` also observes.
    private func electNativeClose(of workspace: NativeBrokerWorkspace, in session: NativeBrokerSession) -> Bool {
        state.withLockedValue { storage in
            let removed = session.state.withLockedValue { $0.workspaces.removeValue(forKey: workspace.identifier) } != nil
            guard removed, !storage.closingWorkspaces.contains(workspace.scope),
                  !storage.sessions.values.contains(where: { $0 !== session && $0.retainsNativeWorkspace(workspace) })
            else { return false }
            storage.closingWorkspaces.insert(workspace.scope)
            return true
        }
    }

    private func finishNativeClose(of workspace: NativeBrokerWorkspace, in session: NativeBrokerSession,
                                   host: NativeBrokerHost, closed: Bool) {
        // Restore while the mark still refuses other handles, so no other session can elect a close first.
        if !closed { session.restoreWorkspace(workspace, host: host) }
        _ = state.withLockedValue { $0.closingWorkspaces.remove(workspace.scope) }
    }

    /// Binds a handle unless its native model is being closed; a model mid-close is about to disappear.
    private func bindWorkspace(in session: NativeBrokerSession, host: NativeBrokerHost,
                               source: ProxyRuntimeUpstreamSource, nativeIdentifier: String,
                               path: String?, name: String?) throws -> NativeBrokerWorkspace {
        let workspace = try session.bindWorkspace(host: host, source: source, nativeIdentifier: nativeIdentifier,
                                                  path: path, name: name)
        // Checked after binding: an election that ran first left its mark, and one that runs later sees this handle.
        let closing = state.withLockedValue { storage in
            guard storage.closingWorkspaces.contains(workspace.scope) else { return false }
            _ = session.state.withLockedValue { $0.workspaces.removeValue(forKey: workspace.identifier) }
            return true
        }
        if closing { throw NativeBrokerWorkspaceClosing() }
        return workspace
    }

    private func discoverGUIHosts() throws {
        for process in inventory.runningGUIProcesses() {
            _ = try register(installation: process.installation, guiProcess: process)
        }
    }

    private func withPinnedHost<T: Sendable>(_ host: NativeBrokerHost, session: NativeBrokerSession,
        operation: (NativeBrokerChannel) async throws -> T) async throws -> T {
        try session.state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            state.hostRequests[host.identifier, default: 0] += 1
        }
        defer { session.releaseHost(host.identifier); closeUnusedChannels(in: session) }
        let channel = try await channel(for: host, session: session)
        return try await operation(channel)
    }

    private func listWorkspaces(_ request: ProxyRuntimeRequest, session: NativeBrokerSession,
                        cancellation: NativeHostBrokerCancellation) async throws -> JSONValue {
        try discoverGUIHosts()
        let targets = hosts().filter {
            if let gui = $0.guiProcess { return inventory.isGUIProcessRunning(gui) }
            return $0.identifier == Self.defaultHostIdentifier || $0.runtimeIfStarted != nil
        }
        var entries: [JSONValue] = []
        var errors: [JSONValue] = []
        for host in targets {
            do {
                let listed = try await withPinnedHost(host, session: session) { channel in
                    let source = try channel.source()
                    let entries = try await workspaceEntries(host: host, channel: channel, source: source,
                                                             request: request, cancellation: cancellation)
                    return try entries.compactMap { entry -> NativeBrokerWorkspace? in
                        do {
                            return try bindWorkspace(in: session, host: host, source: source,
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

    private func workspaceEntries(host: NativeBrokerHost, channel: NativeBrokerChannel,
                          source: ProxyRuntimeUpstreamSource, request: ProxyRuntimeRequest,
                          cancellation: NativeHostBrokerCancellation) async throws -> [NativeBrokerWorkspaceEntry] {
        let gui = host.guiProcess != nil
        let native = try Self.toolRequest(request, name: gui ? "XcodeListWindows" : Self.listWorkspacesTool,
                                         arguments: [:])
        let value = try Self.result(in: await channel.execute(native, source: source, cancellation: cancellation))
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
                       session: NativeBrokerSession, cancellation: NativeHostBrokerCancellation) async throws -> JSONValue {
        guard let path = Self.string(arguments["path"]) else {
            throw NativeHostBrokerError("XcodeOpenWorkspace requires path")
        }
        let hostIdentifier = Self.string(arguments["hostIdentifier"]) ?? Self.defaultHostIdentifier
        guard let host = state.withLockedValue({ $0.hosts[hostIdentifier] }) else {
            throw NativeHostBrokerError("Unknown hostIdentifier; call XcodeMCPKitListHosts")
        }
        return try await withPinnedHost(host, session: session) { channel in
            let source = try channel.source()
            if host.guiProcess != nil {
                let entries = try await workspaceEntries(host: host, channel: channel, source: source,
                                                        request: request, cancellation: cancellation)
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
                let workspace = try bindWorkspace(in: session, host: host, source: source, nativeIdentifier: entry.nativeIdentifier,
                                                          path: entry.path, name: nil)
                return try Self.toolResult(workspace.descriptor)
            }
            let native = try Self.toolRequest(request, name: Self.openWorkspaceTool,
                                             arguments: ["path": .string(path)])
            let value = try Self.result(in: await channel.execute(native, source: source, cancellation: cancellation))
            if Self.isToolError(value) { return value }
            let payload = try Self.toolPayload(value)
            guard let identifier = Self.string(payload["workspaceIdentifier"]) else {
                throw NativeHostBrokerError("Native XcodeOpenWorkspace returned no workspaceIdentifier")
            }
            let workspace = try bindWorkspace(in: session, host: host, source: source, nativeIdentifier: identifier,
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
        NativeHostBrokerError("This reference belongs to an earlier Xcode connection. Open or list workspaces again, or start a new session.")
    }

    private static func workspaceConflict(_ workspace: NativeBrokerWorkspace,
        device: NativeBrokerDeviceSession?, launch: NativeBrokerLaunchSession?) -> String? {
        if let device, workspace.hostIdentifier != device.hostIdentifier || workspace.source != device.source
            || device.workspace.map({ !workspace.hasSameNativeScope(as: $0) }) == true {
            return "The workspace and device session belong to different execution contexts"
        }
        if let launch, workspace.hostIdentifier != launch.hostIdentifier || workspace.source != launch.source
            || launch.workspace.map({ !workspace.hasSameNativeScope(as: $0) }) == true {
            return "The workspace and launch session belong to different execution contexts"
        }
        return nil
    }

    private func callNativeTool(_ name: String, arguments: [String: JSONValue], request: ProxyRuntimeRequest,
                       session: NativeBrokerSession, admission: Admission,
                       cancellation: NativeHostBrokerCancellation) async throws -> ProxyRuntimeReply {
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
                let opened = try await openWorkspace(["path": .string(selector)], request: request,
                                                     session: session, cancellation: cancellation)
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
        let channel = try await channel(for: host, session: session)
        let source = try channel.source()
        guard [workspace?.source, admission.deviceSession?.source, admission.launchSession?.source]
            .compactMap({ $0 }).allSatisfy({ $0 == source }) else {
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
        var catalogRequest = try ProxyRuntimeRequest(json: .object([
            "jsonrpc": .string("2.0"), "id": .string("broker-catalog-" + UUID().uuidString),
            "method": .string("tools/list"),
        ]), headerSessionExists: true, prefersEventStream: false)
        catalogRequest.deadline = request.deadline
        catalogRequest.prefersCachedToolsCatalog = true
        let nativeCatalog = try Self.result(in: await channel.execute(catalogRequest, cancellation: cancellation))
        let native = try XcodeToolCatalog.nativeCall(name: name, arguments: nativeArguments,
            nativeCatalog: nativeCatalog)
        let forwarded = try Self.toolRequest(request, name: native.name, arguments: native.arguments)
        let reply = try await channel.execute(forwarded, source: source, cancellation: cancellation)
        let value = try Self.result(in: reply)
        if Self.isToolError(value) {
            return try Self.externalReply(reply, session: session.identifier, hostIdentifier: host.identifier)
        }
        var device = admission.deviceSession
        var launch = admission.launchSession
        if name == "RunProject" {
            let payload = try Self.toolPayload(value)
            if let nativeID = Self.string(payload["launchSessionReference"]) {
                launch = try session.bindLaunchSession(host: host, source: source, nativeIdentifier: nativeID,
                                                       workspace: workspace)
            }
        }
        if name == "DeviceInteractionStartSession" {
            let payload = try Self.toolPayload(value)
            guard let nativeID = Self.string(payload["interactionSessionKey"]) ?? Self.string(payload["interactSessionKey"]) else {
                throw NativeHostBrokerError("Native device interaction returned no session key")
            }
            device = try session.bindDeviceSession(host: host, source: source, nativeIdentifier: nativeID,
                                                   workspace: workspace)
        }
        if name == "DeviceInteractionEndSession", let device {
            _ = session.state.withLockedValue { $0.deviceSessions.removeValue(forKey: device.identifier) }
        }
        if workspace == nil, name == "XcodeNewProject" {
            let payload = try Self.toolPayload(value)
            if let nativeID = Self.string(payload["workspaceIdentifier"]) {
                workspace = try bindWorkspace(in: session, host: host, source: source, nativeIdentifier: nativeID,
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
