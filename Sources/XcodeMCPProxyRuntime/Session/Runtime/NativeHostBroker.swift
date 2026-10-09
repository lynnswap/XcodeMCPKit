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
        var sessions: [ProxySessionID: NativeBrokerSession] = [:]
        var backendBindings: [ProxySessionID: Binding] = [:]
        var closing: [UUID: Task<Void, Never>] = [:]
        var stopped = false
        var resetsInProgress = 0
    }
    private let state = NIOLockedValueBox(State())
    private let eventSource = ProxyRuntimeEventSource()
    private let configuration: ProxyRuntimeConfiguration
    private let inventory: XcodeHostInventory
    private let factory: RuntimeFactory
    private let clock: ClockClient
    static let defaultHostIdentifier = "host-default"
    static let listTool = "XcodeMCPKitListHosts"
    static let selectTool = "XcodeMCPKitSelectHost"

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

    private func register(installation: XcodeHostInstallation, identifier: String? = nil,
                          independent: Bool = false) throws -> NativeBrokerHost {
        try state.withLockedValue { storage in
            guard !storage.stopped else { throw CancellationError() }
            if !independent, let id = storage.installations[installation.developerDirectory],
               let host = storage.hosts[id] { return host }
            let id = identifier ?? "host-" + UUID().uuidString
            var config = configuration
            config.developerDirectoryURL = installation.developerDirectory
            let frozenConfig = config
            let host = NativeBrokerHost(identifier: id, index: storage.hosts.count,
                installation: installation, create: { [factory] in try factory(frozenConfig) },
                receive: { [weak self] event in self?.receive(event, from: id) })
            storage.hosts[id] = host
            if !independent { storage.installations[installation.developerDirectory] = id }
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
            eventSource.emit(.sessionOpened(sessionID: sessionID))
            let parameters: JSONValue
            if case .object(let values)? = message.decodedJSON {
                parameters = values["params"] ?? .object([:])
            } else { parameters = .object([:]) }
            let session = NativeBrokerSession(identifier: sessionID, defaultHost: Self.defaultHostIdentifier,
                                               initializeParameters: parameters)
            let registered = state.withLockedValue { storage in
                guard !storage.stopped, storage.resetsInProgress == 0 else { return false }
                storage.sessions[sessionID] = session
                return true
            }
            if !registered {
                eventSource.emit(.sessionClosed(sessionID: sessionID))
                return nil
            }
        }
        guard let session = state.withLockedValue({ $0.resetsInProgress == 0 ? $0.sessions[sessionID] : nil }) else { return nil }
        let admission = session.state.withLockedValue { storage -> (String, UInt64)? in
            guard !storage.closed else { return nil }
            storage.activeRequests += 1
            storage.activity = DispatchTime.now().uptimeNanoseconds
            if Self.toolName(in: message) == Self.selectTool { storage.selectionRevision &+= 1 }
            return (storage.selectedHost, storage.selectionRevision)
        }
        guard let admission else { return nil }
        let key = UUID()
        let admittedMessage = message
        var timeoutReply = ProxyRuntimeReply.mcpError(id: requestID, code: -32000,
            message: "upstream timeout", sessionID: sessionID, prefersEventStream: message.prefersEventStream)
        if let object, case .request("tools/list", _) = JSONRPC.Message.Inspector.kind(of: object),
           (object["params"] as? [String: Any])?["cursor"] == nil {
            timeoutReply = (try? Self.response(id: requestID, result: .object([
                "tools": .array(Self.managementTools),
                "_meta": .object(["com.lynnswap.xcode-mcpkit/nativeCatalogError": .string("upstream timeout")]),
            ]), session: sessionID, eventStream: message.prefersEventStream)) ?? timeoutReply
        }
        let operation = NativeHostBrokerOperation(cancelledReply: cancelled, requestIDKey: requestID?.key,
            deadline: message.deadline, clock: clock, timeoutReply: timeoutReply) { [self] cancellation in
            await process(admittedMessage, in: session, hostIdentifier: admission.0,
                          selectionRevision: admission.1, cancellation: cancellation)
        }
        let retained = session.state.withLockedValue { storage in
            guard !storage.closed else { return false }
            storage.operations[key] = operation
            return true
        }
        if !retained { operation.cancel(reason: .channelInactive) }
        operation.whenComplete { _ in session.state.withLockedValue { $0.operations.removeValue(forKey: key) } }
        return operation
    }

    private func process(_ request: ProxyRuntimeRequest, in session: NativeBrokerSession,
                         hostIdentifier: String, selectionRevision: UInt64,
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
                    "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
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
                var catalog: [String: JSONValue]
                do {
                    let reply = try await forward(request, session: session,
                                                  hostIdentifier: hostIdentifier, cancellation: cancellation)
                    guard case .object(let value) = try Self.result(in: reply) else {
                        throw NativeHostBrokerError("Native catalog is not an object")
                    }
                    catalog = value
                } catch let error as NativeHostBrokerRPCError where error.isInputError {
                    return error.reply
                } catch {
                    try Task.checkCancellation()
                    catalog = ["tools": .array([]), "_meta": .object([
                        "com.lynnswap.xcode-mcpkit/nativeCatalogError": .string(String(describing: error)),
                    ])]
                }
                if object["params"] == nil
                    || (object["params"] as? [String: Any])?["cursor"] == nil {
                    let native: [JSONValue]
                    if case .array(let values)? = catalog["tools"] { native = values } else { native = [] }
                    catalog["tools"] = .array(native + Self.managementTools)
                }
                return try Self.response(id: id, result: .object(catalog), session: session.identifier,
                                         eventStream: request.prefersEventStream)
            case .request("tools/call", _):
                if let parameters = object["params"] as? [String: Any],
                   let name = parameters["name"] as? String,
                   name == Self.listTool || name == Self.selectTool {
                    let result: JSONValue
                    do {
                        if name == Self.listTool {
                            for installation in try await inventory.discover() {
                                _ = try register(installation: installation)
                            }
                            result = .object(["hosts": .array(hosts().map { descriptor($0, for: session) })])
                        } else {
                            result = try await select(parameters["arguments"] as? [String: Any] ?? [:],
                                session: session, revision: selectionRevision, deadline: request.deadline)
                        }
                        return try Self.response(id: id, result: Self.toolResult(result),
                            session: session.identifier, eventStream: request.prefersEventStream)
                    } catch {
                        try Task.checkCancellation()
                        return try Self.response(id: id, result: Self.toolResult(.object([
                            "message": .string(String(describing: error)),
                            "selectedHostIdentifier": .string(session.state.withLockedValue { $0.selectedHost }),
                        ]), isError: true), session: session.identifier, eventStream: request.prefersEventStream)
                    }
                }
                return try await forward(request, session: session,
                                         hostIdentifier: hostIdentifier, cancellation: cancellation)
            case .request, .notification, .other:
                return try await forward(request, session: session,
                                         hostIdentifier: hostIdentifier, cancellation: cancellation)
            }
        } catch is CancellationError {
            return .mcpError(id: id, code: -32800, message: "request cancelled",
                            sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
        } catch {
            return .mcpError(id: id, code: -32000, message: String(describing: error),
                            sessionID: session.identifier, prefersEventStream: request.prefersEventStream)
        }
    }

    private func select(_ arguments: [String: Any], session: NativeBrokerSession,
                        revision: UInt64, deadline: Date?) async throws -> JSONValue {
        guard let id = arguments["hostIdentifier"] as? String,
              var host = state.withLockedValue({ $0.hosts[id] }) else {
            throw NativeHostBrokerError("Choose a hostIdentifier returned by XcodeMCPKitListHosts")
        }
        let createsNew: Bool
        if let value = arguments["createsNewHost"] {
            guard let json = JSONValue(any: value), case .bool(let flag) = json else {
                throw NativeHostBrokerError("createsNewHost must be a boolean")
            }
            createsNew = flag
        } else { createsNew = false }
        if createsNew { host = try register(installation: host.installation, independent: true) }
        let channel = try await channel(for: host, session: session)
        var catalog = try ProxyRuntimeRequest(json: .object([
            "jsonrpc": .string("2.0"), "id": .string("broker-catalog"),
            "method": .string("tools/list"),
        ]), headerSessionExists: true, prefersEventStream: false)
        catalog.deadline = deadline
        _ = try Self.result(in: await channel.execute(catalog, cancellation: NativeHostBrokerCancellation()))
        try Task.checkCancellation()
        let applied = session.state.withLockedValue { storage in
            guard !storage.closed, storage.selectionRevision == revision else { return false }
            storage.selectedHost = host.identifier
            return true
        }
        if applied {
            let data = try JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(
                method: "notifications/tools/list_changed"))
            eventSource.emit(.notification(sessionID: session.identifier, data: data))
        }
        return .object(["host": descriptor(host, for: session), "selectionApplied": .bool(applied),
            "selectedHostIdentifier": .string(session.state.withLockedValue { $0.selectedHost })])
    }

    private func channel(for host: NativeBrokerHost, session: NativeBrokerSession)
        async throws -> NativeBrokerChannel {
        try await session.channel(for: host, register: { [self] backendID in
            try state.withLockedValue { storage in
                guard storage.sessions[session.identifier] === session, !storage.stopped else {
                    throw CancellationError()
                }
                storage.backendBindings[backendID] = Binding(session: session, hostIdentifier: host.identifier)
            }
        }, unregister: { [self] backendID in
            state.withLockedValue { $0.backendBindings.removeValue(forKey: backendID) }
        })
    }

    private func forward(_ request: ProxyRuntimeRequest, session: NativeBrokerSession,
                         hostIdentifier: String, cancellation: NativeHostBrokerCancellation)
        async throws -> ProxyRuntimeReply {
        guard let host = state.withLockedValue({ $0.hosts[hostIdentifier] }) else {
            throw NativeHostBrokerError("Selected host is unavailable")
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
              let host = state.withLockedValue({ $0.hosts[binding.hostIdentifier] }) else {
            throw NativeHostBrokerError("Server request belongs to another session")
        }
        let channel = try await channel(for: host, session: session)
        guard case .object(var object) = json else { throw NativeHostBrokerError("Invalid response") }
        object["id"] = nativeID
        let request = try ProxyRuntimeRequest(json: .object(object), headerSessionExists: true,
                                             prefersEventStream: false)
        return try Self.externalReply(try await channel.execute(request, cancellation: cancellation),
                                  session: session.identifier)
    }

    private func receive(_ event: ProxyRuntimeEvent, from hostIdentifier: String) {
        if case .catalogChanged = event {
            let sessions = state.withLockedValue { Array($0.sessions.values) }
            guard let data = try? JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(
                method: "notifications/tools/list_changed"
            )) else { return }
            for session in sessions where session.state.withLockedValue({
                !$0.closed && $0.protocolVersion != nil && $0.selectedHost == hostIdentifier
            }) {
                eventSource.emit(.notification(sessionID: session.identifier, data: data))
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

    private func descriptor(_ host: NativeBrokerHost, for session: NativeBrokerSession) -> JSONValue {
        var result = host.installation.fields
        result["hostIdentifier"] = .string(host.identifier)
        result["isDefault"] = .bool(host.identifier == Self.defaultHostIdentifier)
        result["isSelected"] = .bool(session.state.withLockedValue { $0.selectedHost } == host.identifier)
        let snapshot = host.snapshot
        result["isReady"] = .bool(snapshot?.catalogAvailable == true)
        if let origin = snapshot?.originMetadata {
            result["origin"] = origin
            if case .object(let fields) = origin {
                result["processIdentifier"] = fields["processID"]
                if let version = fields["xcodeVersion"] { result["xcodeVersion"] = version }
            }
        }
        return .object(result)
    }

    package func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState {
        guard let session = state.withLockedValue({ $0.sessions[id] }) else { return .missing }
        return session.state.withLockedValue { storage in
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
                storage.sessions.removeValue(forKey: session.identifier)
                storage.backendBindings = storage.backendBindings.filter { $0.value.session !== session }
            }
            return expired
        }
        for session in expired { close(session) }
    }
    package func removeSession(_ id: ProxySessionID) {
        let session = state.withLockedValue { storage in
            let session = storage.sessions.removeValue(forKey: id)
            storage.backendBindings = storage.backendBindings.filter { $0.value.session !== session }
            return session
        }
        if let session { close(session) }
    }

    private func close(_ session: NativeBrokerSession) {
        let closing = session.close()
        let key = UUID()
        state.withLockedValue { storage in
            storage.closing[key] = Task { [self] in
                await closing.value
                state.withLockedValue { $0.closing.removeValue(forKey: key) }
            }
        }
        eventSource.emit(.sessionClosed(sessionID: session.identifier))
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
        await withTaskGroup(of: Void.self) { group in
            for host in resources.1 { group.addTask { await host.shutdown() } }
            for task in state.withLockedValue({ Array($0.closing.values) }) { group.addTask { await task.value } }
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
        for host in hosts() { if let runtime = host.runtimeIfStarted { await runtime.reset() } }
    }
}
