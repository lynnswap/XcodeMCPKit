import Foundation
import NIO
import NIOHTTP1

struct HTTPRequestSecurityPolicy: Sendable {
    enum Decision: Sendable, Equatable {
        case allow
        case rejectOrigin
    }

    let configuredHost: String
    let configuredPort: Int

    func evaluate(
        _ head: HTTPRequestHead,
        localAddress: SocketAddress?
    ) -> Decision {
        let originFields = head.headers["Origin"]
        guard originFields.isEmpty == false else {
            return .allow
        }
        guard originFields.count == 1,
            originIsAllowed(originFields[0], localAddress: localAddress)
        else {
            return .rejectOrigin
        }
        return .allow
    }

    private func originIsAllowed(
        _ origin: String,
        localAddress: SocketAddress?
    ) -> Bool {
        guard origin.isEmpty == false,
            origin.lowercased() != "null",
            origin.contains(",") == false,
            origin.contains("%") == false,
            origin.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            origin.rangeOfCharacter(from: .controlCharacters) == nil,
            let components = URLComponents(string: origin),
            components.scheme?.lowercased() == "http",
            components.user == nil,
            components.password == nil,
            components.percentEncodedPath.isEmpty,
            components.query == nil,
            components.fragment == nil,
            let originHost = components.host,
            originHost.isEmpty == false,
            hostIsAllowed(originHost),
            let endpointPort = endpointPort(localAddress: localAddress),
            (components.port ?? 80) == endpointPort
        else {
            return false
        }
        return true
    }

    private func hostIsAllowed(_ originHost: String) -> Bool {
        let origin = Self.normalizedHost(originHost)
        let configured = Self.normalizedHost(configuredHost)

        if Self.isWildcardHost(configured) || Self.isLoopbackHost(configured) {
            return Self.isLoopbackHost(origin)
        }
        return Self.hostsAreEquivalent(origin, configured)
    }

    private func endpointPort(localAddress: SocketAddress?) -> Int? {
        if let port = localAddress?.port, (1...65_535).contains(port) {
            return port
        }
        guard (1...65_535).contains(configuredPort) else {
            return nil
        }
        return configuredPort
    }

    private static func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    private static func hostsAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let lhsIPAddress = canonicalIPAddress(lhs)
        let rhsIPAddress = canonicalIPAddress(rhs)
        if lhsIPAddress != nil || rhsIPAddress != nil {
            return lhsIPAddress == rhsIPAddress
        }
        return lhs == rhs
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" {
            return true
        }
        guard let address = canonicalIPAddress(host) else {
            return false
        }
        if address == "::1" {
            return true
        }
        return address.split(separator: ".", omittingEmptySubsequences: false).first == "127"
    }

    private static func isWildcardHost(_ host: String) -> Bool {
        guard let address = canonicalIPAddress(host) else {
            return false
        }
        return address == "0.0.0.0" || address == "::"
    }

    private static func canonicalIPAddress(_ host: String) -> String? {
        try? SocketAddress(ipAddress: host, port: 0).ipAddress
    }
}
