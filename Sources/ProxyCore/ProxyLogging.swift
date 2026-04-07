import Foundation
import Logging
import NIOConcurrencyHelpers

private struct CompactDateLogHandler: LogHandler {
    private static let cachedFormatter = NIOLockedValueBox<DateFormatter>({
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yy-MM-dd HH:mm:ss"
        return formatter
    }())

    let label: String
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]

    init(label: String, logLevel: Logger.Level) {
        self.label = label
        self.logLevel = logLevel
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= logLevel else { return }

        let mergedMetadata = metadata.merging(explicitMetadata ?? [:], uniquingKeysWith: { _, new in new })
        let timestamp = Self.formatTimestamp(Date())

        var output = "\(timestamp) \(level) \(label):"
        if !mergedMetadata.isEmpty {
            output += " \(Self.formatMetadata(mergedMetadata))"
        }
        output += " \(message)\n"

        guard let data = output.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        cachedFormatter.withLockedValue { formatter in
            formatter.string(from: date)
        }
    }

    private static func formatMetadata(_ metadata: Logger.Metadata) -> String {
        metadata
            .keys
            .sorted()
            .compactMap { key in
                guard let value = metadata[key] else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: " ")
    }
}

public enum ProxyLogging {
    private static let bootstrapState = NIOLockedValueBox(false)
    private static let labelPrefix = "XcodeMCPProxy"

    /// Call from the host application to opt into StreamLogHandler-based logging.
    /// Do not call this if swift-log is already bootstrapped elsewhere.
    public static func bootstrap(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let shouldBootstrap = bootstrapState.withLockedValue { state in
            if state {
                return false
            }
            state = true
            return true
        }
        guard shouldBootstrap else { return }

        let level = LogLevelParser.resolve(from: environment)

        LoggingSystem.bootstrap { label in
            CompactDateLogHandler(label: label, logLevel: level)
        }
    }

    /// Creates a logger without bootstrapping swift-log.
    /// The host application may call `bootstrap()` explicitly if desired.
    public static func make(_ name: String) -> Logger {
        return Logger(label: "\(labelPrefix).\(name)")
    }

}

enum LogLevelParser {
    static func resolve(
        from environment: [String: String],
        default defaultLevel: Logger.Level = .info
    ) -> Logger.Level {
        parse(environment["MCP_LOG_LEVEL"])
            ?? parse(environment["LOG_LEVEL"])
            ?? defaultLevel
    }

    static func parse(_ value: String?) -> Logger.Level? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "info":
            return .info
        case "notice":
            return .notice
        case "warn", "warning":
            return .warning
        case "error":
            return .error
        case "critical", "fatal":
            return .critical
        default:
            return nil
        }
    }
}
