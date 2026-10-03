import ABIBridge
import Foundation
import ObjectiveC

/// A lost GUI owner must remain distinguishable from a host that was unavailable
/// before dispatch, so its outstanding mutations are never replayed elsewhere.
package enum NativeGUIConnectionError: Error, CustomStringConvertible, Sendable {
    case disconnected(processIdentifier: Int32)

    package var description: String {
        switch self {
        case .disconnected(let processIdentifier):
            "Connection to Xcode process \(processIdentifier) was lost"
        }
    }
}

@MainActor
package protocol NativeGUIConnectionTransport: AnyObject {
    func activate(connected: @escaping @MainActor @Sendable () -> Void,
                  receive: @escaping @MainActor @Sendable (Data) -> Void,
                  invalidated: @escaping @MainActor @Sendable ((any Error)?) -> Void) throws
    func send(_ message: Data, reply: @escaping @MainActor @Sendable (Result<Data, any Error>) -> Void) throws
    func sendOneWay(_ message: Data) throws
    func invalidate() throws
}

/// Owns one native GUI connection and one MCP client's session context. Native
/// request/response bodies pass through unchanged; the caller owns their codec.
@MainActor
package final class NativeGUIConnection {
    private enum Phase { case idle, connecting, active, closed(any Error) }

    package let processIdentifier: Int32
    package let messages: AsyncStream<Data>
    package var isConnected: Bool { if case .active = phase { true } else { false } }
    package var terminationError: (any Error)? { if case .closed(let error) = phase { error } else { nil } }

    private let transport: any NativeGUIConnectionTransport
    private let messageContinuation: AsyncStream<Data>.Continuation
    private var phase = Phase.idle
    private var cleanupFailure: (any Error)?
    private var connectionWaiter: CheckedContinuation<Void, any Error>?
    private var pendingReplies: [UUID: CheckedContinuation<Data, any Error>] = [:]

    package init(processIdentifier: Int32, transport: any NativeGUIConnectionTransport) {
        self.processIdentifier = processIdentifier
        self.transport = transport
        (messages, messageContinuation) = AsyncStream.makeStream()
    }

    package static func connect(to processIdentifier: Int32, initializingWith message: Data,
                                installation: NativeXcodeInstallation,
                                timeout: Duration = .seconds(30)) async throws -> NativeGUIConnection {
        let transport = try await BoardServicesGUITransport(
            processIdentifier: processIdentifier,
            messagingBinary: installation.framework("IDEIntelligenceMessaging", in: "PlugIns"))
        let connection = NativeGUIConnection(processIdentifier: processIdentifier, transport: transport)
        try await connection.start(initializingWith: message, timeout: timeout)
        return connection
    }

    package func start(initializingWith message: Data, timeout: Duration = .seconds(30)) async throws {
        guard case .idle = phase else {
            throw NativeRuntimeError.invalidRequest("A native GUI connection can only be started once")
        }
        try Task.checkCancellation()
        phase = .connecting
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, case .connecting = self.phase else { return }
            self.close(with: NativeRuntimeError.unavailable("Timed out connecting to Xcode process \(self.processIdentifier)"))
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connectionWaiter = continuation
                    do {
                        try transport.activate(connected: { [weak self] in
                            guard let self, case .connecting = self.phase else { return }
                            self.phase = .active
                            self.connectionWaiter?.resume()
                            self.connectionWaiter = nil
                        }, receive: { [weak self] data in
                            guard let self, case .active = self.phase else { return }
                            self.messageContinuation.yield(data)
                        }, invalidated: { [weak self] error in
                            guard let self else { return }
                            self.close(with: error ?? self.disconnectionError)
                        })
                    } catch { close(with: error) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.close(with: CancellationError()) }
            }
            try Task.checkCancellation()
            try sendOneWay(message)
        } catch {
            if let cleanup = close(with: error) {
                throw NativeRuntimeError.invocation("\(error); GUI connection cleanup also failed: \(cleanup)")
            }
            throw error
        }
    }

    /// For action requests, supply the matching native cancelToolCall message.
    /// Cancellation retains the request until Xcode acknowledges it or the
    /// connection ends, so a cancelled caller cannot abandon an active mutation.
    package func request(_ message: Data, cancellationMessage: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard case .active = phase else { throw disconnectionError }
        let id = UUID()
        let result: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingReplies[id] = continuation
                do {
                    try transport.send(message) { [weak self] result in
                        self?.pendingReplies.removeValue(forKey: id)?.resume(with: result)
                    }
                } catch {
                    pendingReplies.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id, message: cancellationMessage) }
        }
        try Task.checkCancellation()
        return result
    }

    package func sendOneWay(_ message: Data) throws {
        guard case .active = phase else { throw disconnectionError }
        try transport.sendOneWay(message)
    }

    package func invalidate() throws {
        close(with: disconnectionError)
        if let cleanupFailure { throw cleanupFailure }
    }

    private var disconnectionError: NativeGUIConnectionError {
        .disconnected(processIdentifier: processIdentifier)
    }

    private func cancelRequest(_ id: UUID, message: Data?) {
        guard pendingReplies[id] != nil else { return }
        if let message {
            do { try transport.sendOneWay(message) }
            catch { close(with: error) }
        } else {
            pendingReplies.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    @discardableResult
    private func close(with error: any Error) -> (any Error)? {
        if case .closed = phase { return nil }
        phase = .closed(error)
        var completionError: any Error = error
        var cleanupError: (any Error)?
        do { try transport.invalidate() }
        catch let cleanup {
            cleanupFailure = cleanup
            cleanupError = cleanup
            completionError = NativeRuntimeError.invocation("\(error); GUI connection cleanup also failed: \(cleanup)")
            phase = .closed(completionError)
        }
        connectionWaiter?.resume(throwing: completionError)
        connectionWaiter = nil
        let replies = pendingReplies.values
        pendingReplies.removeAll()
        for continuation in replies { continuation.resume(throwing: completionError) }
        messageContinuation.finish()
        return cleanupError
    }
}

@MainActor
private final class BoardServicesGUITransport: NativeGUIConnectionTransport {
    private let processIdentifier: Int32
    private let interface: AnyObject
    private let interfaceImage: ResolvedSymbol
    private var listener: AnyObject?
    private var assertion: AnyObject?
    private var connection: AnyObject?
    private var remoteTarget: AnyObject?
    private var delegate: NativeGUIListenerDelegate?
    private var receiver: NativeGUIReceiver?
    private var didConnect: (@MainActor @Sendable () -> Void)?
    private var didReceive: (@MainActor @Sendable (Data) -> Void)?
    private var didInvalidate: (@MainActor @Sendable ((any Error)?) -> Void)?
    private var invalidated = false

    init(processIdentifier: Int32, messagingBinary: URL) async throws {
        self.processIdentifier = processIdentifier
        let function = try unsafe await ABIRuntime.shared.cFunction(
            named: "MCPBridgeConnectionInterface",
            as: ((UnsafeRawPointer) -> UnsafeMutableRawPointer).self,
            in: .path(messagingBinary), loading: .loadedOnly)
        let service: NSString = "com.apple.dt.mcpbridge.tool-service"
        let pointer = try unsafe function.unsafeInvoke(UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque()))
        interface = unsafe Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        interfaceImage = unsafe function.symbol
    }

    func activate(connected: @escaping @MainActor @Sendable () -> Void,
                  receive: @escaping @MainActor @Sendable (Data) -> Void,
                  invalidated: @escaping @MainActor @Sendable ((any Error)?) -> Void) throws {
        didConnect = connected
        didReceive = receive
        didInvalidate = invalidated
        guard let listenerClass = NSClassFromString("BSServiceConnectionListener"),
              let assertionClass = NSClassFromString("RBSAssertion"),
              let targetClass = NSClassFromString("RBSTarget"),
              let attributeClass = NSClassFromString("RBSDomainAttribute"),
              let configurationClass = NSClassFromString("BSServicesConfiguration") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's native GUI connection types are unavailable")
        }
        // BoardServices traps for an unregistered domain/service rather than
        // returning an error. Check the registered specification before dispatch.
        let configuration = try nativeGUICall(configurationClass as AnyObject, "defaultConfiguration", returning: AnyObject.self)
        guard let domain = try nativeGUICall(configuration, "domainForIdentifier:", "com.apple.dt.mcpbridge.services", returning: AnyObject?.self),
              try nativeGUICall(domain, "serviceForIdentifier:", "com.apple.dt.mcpbridge.tool-service", returning: AnyObject?.self) != nil else {
            throw NativeRuntimeError.unsupportedContract("Native host bundle is missing its BoardServices GUI service specification")
        }
        if let nativeProtocol = unsafe objc_getProtocol("BSServiceConnectionListenerDelegate") {
            class_addProtocol(NativeGUIListenerDelegate.self, nativeProtocol)
        }
        if let nativeProtocol = unsafe objc_getProtocol("MCPBridgeConnectionProtocol") {
            class_addProtocol(NativeGUIReceiver.self, nativeProtocol)
        }
        let delegate = NativeGUIListenerDelegate { [weak self] reference in
            Task { @MainActor in self?.accept(reference.object) }
        }
        self.delegate = delegate
        let configure: NativeGUIConfigure = { [weak self] config in
            do {
                try nativeGUISend(config, "setDomain:", "com.apple.dt.mcpbridge.services")
                try nativeGUISend(config, "setService:", "com.apple.dt.mcpbridge.tool-service")
                try nativeGUISend(config, "setDelegate:", delegate)
            } catch {
                Task { @MainActor in self?.didInvalidate?(error) }
            }
        }
        listener = try nativeGUICall(listenerClass as AnyObject, "listenerWithConfigurator:", configure, returning: AnyObject.self)
        guard let listener else { throw NativeRuntimeError.invocation("Native GUI listener creation returned no listener") }
        try nativeGUISend(listener, "activate")
        let endpoint = try nativeGUICall(listener, "endpoint", returning: AnyObject.self)
        try nativeGUISend(endpoint, "saveAsInjectorEndowmentForKey:", "com.apple.dt.mcpbridge.endpoint-injection")
        let target = try nativeGUICall(targetClass as AnyObject, "targetWithPid:", processIdentifier, returning: AnyObject.self)
        let attributeMethod = try ABIRuntime.shared.object(attributeClass as AnyObject).method(
            selector: "attributeWithDomain:name:", as: ((String, String) -> AnyObject).self)
        let attribute = try unsafe attributeMethod.unsafeInvoke("com.apple.mcpbridge", "MCPWorkspaceEndpointInjection")
        let allocated = try nativeGUICall(assertionClass as AnyObject, "alloc", returning: AnyObject.self)
        let initialize = try ABIRuntime.shared.object(allocated).method(
            selector: "initWithExplanation:target:attributes:", as: ((String, AnyObject, [AnyObject]) -> AnyObject).self)
        assertion = try unsafe initialize.unsafeInvoke("XcodeMCPKit native workspace connection", target, [attribute])
        guard let assertion else { throw NativeRuntimeError.invocation("Native GUI assertion creation returned no assertion") }
        var error: AnyObject?
        let acquire = try unsafe ABIRuntime.shared.object(assertion).method(
            selector: "acquireWithError:", as: ((UnsafeMutablePointer<AnyObject?>) -> Bool).self)
        let succeeded = try withUnsafeMutablePointer(to: &error) { pointer in try unsafe acquire.unsafeInvoke(pointer) }
        if !succeeded {
            if let error = error as? NSError { throw error }
            throw NativeRuntimeError.unavailable("RunningBoard declined the native GUI connection")
        }
    }

    func send(_ message: Data, reply: @escaping @MainActor @Sendable (Result<Data, any Error>) -> Void) throws {
        guard !invalidated, let remoteTarget else {
            throw NativeGUIConnectionError.disconnected(processIdentifier: processIdentifier)
        }
        let send = try ABIRuntime.shared.object(remoteTarget).method(
            selector: "sendMessage:replyHandler:", as: ((Data, @escaping NativeGUIReply) -> Void).self)
        let callback: NativeGUIReply = { data, error in
            Task { @MainActor in
                if let error { reply(.failure(error)) }
                else if let data { reply(.success(data)) }
                else { reply(.failure(NativeRuntimeError.invocation("Xcode returned an empty native GUI reply"))) }
            }
        }
        try unsafe send.unsafeInvoke(message, callback)
    }

    func sendOneWay(_ message: Data) throws {
        guard !invalidated, let remoteTarget else {
            throw NativeGUIConnectionError.disconnected(processIdentifier: processIdentifier)
        }
        try nativeGUISend(remoteTarget, "sendMessage:", message)
    }

    func invalidate() throws {
        guard !invalidated else { return }
        invalidated = true
        didConnect = nil
        didReceive = nil
        didInvalidate = nil
        let resources: [(String, AnyObject?)] = [("connection", connection), ("listener", listener), ("assertion", assertion)]
        var failures: [String] = []
        for (name, resource) in resources {
            guard let resource else { continue }
            do { try nativeGUISend(resource, "invalidate") }
            catch { failures.append("\(name): \(error)") }
        }
        connection = nil
        remoteTarget = nil
        listener = nil
        assertion = nil
        delegate = nil
        receiver = nil
        if !failures.isEmpty {
            throw NativeRuntimeError.invocation("Native GUI connection cleanup failed: \(failures.joined(separator: "; "))")
        }
    }

    private func accept(_ connection: AnyObject) {
        guard !invalidated, self.connection == nil else {
            do { try nativeGUISend(connection, "invalidate") }
            catch { didInvalidate?(error) }
            return
        }
        do {
            let token = try nativeGUICall(connection, "remoteToken", returning: AnyObject.self)
            let peer = try nativeGUICall(token, "pid", returning: Int32.self)
            guard peer == processIdentifier else { try nativeGUISend(connection, "invalidate"); return }
        } catch { didInvalidate?(error); return }
        self.connection = connection
        let receiver = NativeGUIReceiver { [weak self] message in
            Task { @MainActor in self?.didReceive?(message) }
        }
        self.receiver = receiver
        let configuration: NativeGUIConfigure = { [weak self, interface] config in
            do {
                try nativeGUISend(config, "setInterface:", interface)
                try nativeGUISend(config, "setInterfaceTarget:", receiver)
                try nativeGUISend(config, "setTargetQueue:", DispatchQueue.main)
                let active: NativeGUIConnectionHandler = { object in
                    let reference = NativeGUIObject(object)
                    Task { @MainActor in
                        guard let self, !self.invalidated else { return }
                        do {
                            self.remoteTarget = try nativeGUICall(reference.object, "remoteTarget", returning: AnyObject.self)
                            self.didConnect?()
                        } catch { self.didInvalidate?(error) }
                    }
                }
                let invalid: NativeGUIConnectionHandler = { _ in
                    Task { @MainActor in self?.didInvalidate?(nil) }
                }
                try nativeGUISend(config, "setActivationHandler:", active)
                try nativeGUISend(config, "setInvalidationHandler:", invalid)
            } catch {
                Task { @MainActor in self?.didInvalidate?(error) }
            }
        }
        do {
            try nativeGUISend(connection, "configureConnection:", configuration)
            try nativeGUISend(connection, "activate")
        } catch { didInvalidate?(error) }
    }
}

private typealias NativeGUIConfigure = @convention(block) (AnyObject) -> Void
private typealias NativeGUIReply = @convention(block) (Data?, NSError?) -> Void
private typealias NativeGUIConnectionHandler = @convention(block) (AnyObject) -> Void

// BoardServices objects are retained across the callback handoff. Their state is
// accessed only after reaching the main actor; this wrapper permits that handoff
// without declaring arbitrary Objective-C objects safe for concurrent access.
private struct NativeGUIObject: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}

private final class NativeGUIListenerDelegate: NSObject {
    let handler: @Sendable (NativeGUIObject) -> Void
    init(handler: @escaping @Sendable (NativeGUIObject) -> Void) { self.handler = handler }
    @objc func listener(_ listener: AnyObject, didReceiveConnection connection: AnyObject, withContext context: AnyObject) {
        handler(NativeGUIObject(connection))
    }
}

private final class NativeGUIReceiver: NSObject {
    let handler: @Sendable (Data) -> Void
    init(handler: @escaping @Sendable (Data) -> Void) { self.handler = handler }
    @objc func sendMessage(_ data: Data) { handler(data) }
    @objc func sendMessage(_ data: Data, replyHandler: NativeGUIReply) {
        replyHandler(nil, NSError(domain: "XcodeMCPKit.NativeGUI", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected native request from Xcode"]))
    }
}

private func nativeGUICall<T>(_ object: AnyObject, _ selector: String, returning: T.Type) throws -> T {
    let call = try ABIRuntime.shared.object(object).method(selector: selector, as: (() -> T).self)
    return try unsafe call.unsafeInvoke()
}
private func nativeGUICall<A, T>(_ object: AnyObject, _ selector: String, _ argument: A, returning: T.Type) throws -> T {
    let call = try ABIRuntime.shared.object(object).method(selector: selector, as: ((A) -> T).self)
    return try unsafe call.unsafeInvoke(argument)
}
private func nativeGUISend(_ object: AnyObject, _ selector: String) throws {
    try nativeGUICall(object, selector, returning: Void.self)
}
private func nativeGUISend<A>(_ object: AnyObject, _ selector: String, _ argument: A) throws {
    try nativeGUICall(object, selector, argument, returning: Void.self)
}
