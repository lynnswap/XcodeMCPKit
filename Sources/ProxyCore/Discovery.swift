import Foundation
import Darwin
import Network

public struct DiscoveryRecord: Codable, Sendable {
    public var url: String
    public var host: String
    public var port: Int
    public var pid: Int
    public var updatedAt: Date

    public init(
        url: String,
        host: String,
        port: Int,
        pid: Int,
        updatedAt: Date
    ) {
        self.url = url
        self.host = host
        self.port = port
        self.pid = pid
        self.updatedAt = updatedAt
    }
}

public enum Discovery {
    public static var defaultFileURL: URL {
        ProxyFilesystemLocations.discoveryFileURL()
    }

    public static func read(overrideURL: URL? = nil) -> DiscoveryRecord? {
        let url = fileURL(overrideURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? decoder.decode(DiscoveryRecord.self, from: data) else { return nil }
        guard isProcessAlive(record.pid) else { return nil }
        guard isLoopbackURL(record.url) else { return nil }
        return record
    }

    public static func write(record: DiscoveryRecord, overrideURL: URL? = nil) throws {
        let url = fileURL(overrideURL)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic])
    }

    public static func makeRecord(
        host: String,
        port: Int,
        pid: Int,
        scheme: String = "http"
    ) -> DiscoveryRecord? {
        guard port > 0 else { return nil }
        let url = makeURLString(host: host, port: port, scheme: scheme)
        return DiscoveryRecord(
            url: url,
            host: host,
            port: port,
            pid: pid,
            updatedAt: Date()
        )
    }

    private static func fileURL(_ overrideURL: URL?) -> URL {
        if let overrideURL {
            return overrideURL
        }
        return defaultFileURL
    }

    private static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid_t(pid), 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func makeURLString(host: String, port: Int, scheme: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "/mcp"
        if let url = components.url {
            return url.absoluteString
        }
        let normalizedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(normalizedHost):\(port)/mcp"
    }

    private static func isLoopbackURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let host = components.host else {
            return false
        }
        return isLoopbackHost(normalizeHost(host))
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if isIPv4Loopback(host) { return true }
        return isIPv6Loopback(host)
    }

    private static func normalizeHost(_ host: String) -> String {
        let value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        guard let address = IPv4Address(host) else { return false }
        return address.rawValue.first == 127
    }

    private static func isIPv6Loopback(_ host: String) -> Bool {
        guard let address = IPv6Address(host) else { return false }
        let bytes = address.rawValue
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
}
