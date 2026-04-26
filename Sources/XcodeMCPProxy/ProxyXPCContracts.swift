import Foundation

public enum ProxyXPCServiceConfiguration {
    public static let machServiceName = "com.xcodemcproxy.server"
}

public struct ProxyXPCClientStatus: Codable, Sendable, Equatable {
    public let sessionID: String
    public let activeCorrelatedRequestCount: Int

    public init(sessionID: String, activeCorrelatedRequestCount: Int) {
        self.sessionID = sessionID
        self.activeCorrelatedRequestCount = activeCorrelatedRequestCount
    }
}

public struct ProxyXPCStatusPayload: Codable, Sendable, Equatable {
    public let endpointDisplay: String
    public let reachable: Bool
    public let version: String
    public let xcodeHealth: String
    public let activeClientCount: Int
    public let activeCorrelatedRequestCount: Int
    public let clients: [ProxyXPCClientStatus]
    public let fetchError: String?

    public init(
        endpointDisplay: String,
        reachable: Bool,
        version: String,
        xcodeHealth: String,
        activeClientCount: Int,
        activeCorrelatedRequestCount: Int,
        clients: [ProxyXPCClientStatus],
        fetchError: String?
    ) {
        self.endpointDisplay = endpointDisplay
        self.reachable = reachable
        self.version = version
        self.xcodeHealth = xcodeHealth
        self.activeClientCount = activeClientCount
        self.activeCorrelatedRequestCount = activeCorrelatedRequestCount
        self.clients = clients
        self.fetchError = fetchError
    }
}

@objc public protocol ProxyXPCClientProtocol {
    func statusDidUpdate(_ payload: Data)
}

@objc public protocol ProxyXPCControlProtocol {
    func ping(_ reply: @escaping (String) -> Void)
    func fetchStatus(_ reply: @escaping (Data) -> Void)
    func registerClient(_ reply: @escaping (Data) -> Void)
    func unregisterClient(_ reply: @escaping () -> Void)
    func requestShutdown(_ reply: @escaping (Bool) -> Void)
}