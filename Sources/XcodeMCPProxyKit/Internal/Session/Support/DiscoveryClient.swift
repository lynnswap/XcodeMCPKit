import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime

struct DiscoveryClient: DependencyClient {
    var defaultFileURL: @Sendable () -> URL
    var read: @Sendable (_ overrideURL: URL?) -> DiscoveryRecord?
    var write: @Sendable (_ record: DiscoveryRecord, _ overrideURL: URL?) throws -> Void
    var makeRecord: @Sendable (_ host: String, _ port: Int, _ pid: Int, _ scheme: String) ->
        DiscoveryRecord?

    init(
        defaultFileURL: @escaping @Sendable () -> URL,
        read: @escaping @Sendable (_ overrideURL: URL?) -> DiscoveryRecord?,
        write: @escaping @Sendable (_ record: DiscoveryRecord, _ overrideURL: URL?) throws -> Void,
        makeRecord: @escaping @Sendable (_ host: String, _ port: Int, _ pid: Int, _ scheme: String) ->
            DiscoveryRecord?
    ) {
        self.defaultFileURL = defaultFileURL
        self.read = read
        self.write = write
        self.makeRecord = makeRecord
    }

    static let liveValue = live()

    static let testValue = Self(
        defaultFileURL: {
            URL(fileURLWithPath: "/tmp/XcodeMCPProxy/endpoint.json")
        },
        read: { _ in nil },
        write: { _, _ in },
        makeRecord: { host, port, pid, scheme in
            guard port > 0 else { return nil }
            return DiscoveryRecord(
                url: Discovery.makeURLString(host: host, port: port, scheme: scheme),
                host: host,
                port: port,
                pid: pid,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
    )

    static func live(
        defaultFileURL: @escaping @Sendable () -> URL = {
            ProxyFilesystemLocations.discoveryFileURL()
        },
        loadRecord: @escaping @Sendable (_ url: URL) throws -> DiscoveryRecord = {
            try Discovery.loadRecord(from: $0)
        },
        persistRecord: @escaping @Sendable (_ record: DiscoveryRecord, _ url: URL) throws -> Void = {
            try Discovery.persist(record: $0, to: $1)
        },
        createDirectory: @escaping @Sendable (_ url: URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        isProcessAlive: @escaping @Sendable (_ pid: Int) -> Bool = {
            ProcessControlClient.liveValue.isProcessAlive($0)
        },
        now: @escaping @Sendable () -> Date = {
            Date()
        }
    ) -> Self {
        Self(
            defaultFileURL: defaultFileURL,
            read: { overrideURL in
                let url = overrideURL ?? defaultFileURL()
                guard let record = try? loadRecord(url) else { return nil }
                guard isProcessAlive(record.pid) else { return nil }
                guard Discovery.isLoopbackURL(record.url) else { return nil }
                return record
            },
            write: { record, overrideURL in
                let url = overrideURL ?? defaultFileURL()
                try createDirectory(url.deletingLastPathComponent())
                try persistRecord(record, url)
            },
            makeRecord: { host, port, pid, scheme in
                guard port > 0 else { return nil }
                return DiscoveryRecord(
                    url: Discovery.makeURLString(host: host, port: port, scheme: scheme),
                    host: host,
                    port: port,
                    pid: pid,
                    updatedAt: now()
                )
            }
        )
    }
}
