import Foundation
import Logging
import NIOConcurrencyHelpers

private final class ProxyXPCClientRegistry {
    private struct ClientEntry {
        let connection: NSXPCConnection
        var isRegistered: Bool
    }

    private let state = NIOLockedValueBox<[ObjectIdentifier: ClientEntry]>([:])

    func add(_ connection: NSXPCConnection) {
        state.withLockedValue { state in
            state[ObjectIdentifier(connection)] = ClientEntry(connection: connection, isRegistered: false)
        }
    }

    func remove(_ connection: NSXPCConnection) {
        state.withLockedValue { state in
            state.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    func markRegistered(_ connection: NSXPCConnection, value: Bool) {
        state.withLockedValue { state in
            let key = ObjectIdentifier(connection)
            guard var entry = state[key] else { return }
            entry.isRegistered = value
            state[key] = entry
        }
    }

    func registeredConnections() -> [NSXPCConnection] {
        state.withLockedValue { state in
            state.values.compactMap { entry in
                entry.isRegistered ? entry.connection : nil
            }
        }
    }
}

public final class ProxyXPCServiceHost: NSObject, NSXPCListenerDelegate, ProxyXPCControlProtocol {
    public typealias StatusProvider = () -> ProxyXPCStatusPayload
    public typealias ShutdownHandler = () -> Void

    private let listener = NSXPCListener(machServiceName: ProxyXPCServiceConfiguration.machServiceName)
    private let registry = ProxyXPCClientRegistry()
    private let statusProvider: StatusProvider
    private let shutdownHandler: ShutdownHandler
    private let encoder = JSONEncoder()
    private let logger = ProxyLogging.make("xpc")
    private let lastBroadcastPayload = NIOLockedValueBox<Data?>(nil)

    private var isRunning = false
    public init(statusProvider: @escaping StatusProvider, shutdownHandler: @escaping ShutdownHandler) {
        self.statusProvider = statusProvider
        self.shutdownHandler = shutdownHandler
        super.init()
        listener.delegate = self
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        listener.resume()
        logger.info("XPC listener started", metadata: ["service": "\(ProxyXPCServiceConfiguration.machServiceName)"])
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        listener.invalidate()
        logger.info("XPC listener stopped", metadata: ["service": "\(ProxyXPCServiceConfiguration.machServiceName)"])
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ProxyXPCControlProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: ProxyXPCClientProtocol.self)

        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.registry.remove(newConnection)
        }

        registry.add(newConnection)
        newConnection.resume()
        return true
    }

    public func ping(_ reply: @escaping (String) -> Void) {
        reply("pong")
    }

    public func fetchStatus(_ reply: @escaping (Data) -> Void) {
        reply(encodedStatus())
    }

    public func registerClient(_ reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(encodedStatus())
            return
        }
        registry.markRegistered(connection, value: true)
        let payload = encodedStatus()
        lastBroadcastPayload.withLockedValue { $0 = payload }
        if let client = connection.remoteObjectProxyWithErrorHandler({ [logger] (error: Error) in
            logger.debug("XPC callback delivery failed", metadata: ["error": "\(error)"])
        }) as? ProxyXPCClientProtocol {
            client.statusDidUpdate(payload)
        }
        reply(payload)
    }

    public func unregisterClient(_ reply: @escaping () -> Void) {
        if let connection = NSXPCConnection.current() {
            registry.markRegistered(connection, value: false)
        }
        reply()
    }

    public func requestShutdown(_ reply: @escaping (Bool) -> Void) {
        shutdownHandler()
        reply(true)
    }

    public func pushStatusIfChanged() {
        guard isRunning else { return }
        let payload = encodedStatus()
        let shouldBroadcast = lastBroadcastPayload.withLockedValue { last in
            if last == payload {
                return false
            }
            last = payload
            return true
        }

        if shouldBroadcast {
            broadcast(payload: payload)
        }
    }

    private func broadcast(payload: Data) {
        for connection in registry.registeredConnections() {
            guard let client = connection.remoteObjectProxyWithErrorHandler({ [logger] (error: Error) in
                logger.debug("XPC callback delivery failed", metadata: ["error": "\(error)"])
            }) as? ProxyXPCClientProtocol else {
                continue
            }
            client.statusDidUpdate(payload)
        }
    }

    private func encodedStatus() -> Data {
        do {
            return try encoder.encode(statusProvider())
        } catch {
            logger.error("Failed to encode XPC status payload", metadata: ["error": "\(error)"])
            let fallback = ProxyXPCStatusPayload(
                endpointDisplay: "unavailable",
                reachable: false,
                version: "unknown",
                xcodeHealth: "Unknown",
                activeClientCount: 0,
                activeCorrelatedRequestCount: 0,
                clients: [],
                fetchError: "Failed to encode status payload."
            )
            return (try? encoder.encode(fallback)) ?? Data()
        }
    }
}
