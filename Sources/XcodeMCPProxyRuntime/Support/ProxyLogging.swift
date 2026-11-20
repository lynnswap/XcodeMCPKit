import Foundation
import Logging
import NIOConcurrencyHelpers
import XcodeMCPCore

package enum ProxyLogging {
    private static let bootstrapState = NIOLockedValueBox(false)
    private static let labelPrefix = "XcodeMCPProxy"

    /// Call from the host application to opt into StreamLogHandler-based logging.
    /// Do not call this if swift-log is already bootstrapped elsewhere.
    package static func bootstrap(environment: [String: String] = ProcessInfo.processInfo.environment) {
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
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }

    /// Creates a logger without bootstrapping swift-log.
    /// The host application may call `bootstrap()` explicitly if desired.
    package static func make(_ name: String) -> Logger {
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

extension MCPProcess.Diagnostics {
    /// Forwards a host process session's diagnostics to the server log.
    static var serverLog: Self {
        let logger = Logger(label: "XcodeMCPRuntime.host")
        return Self { severity, message, metadata in
            let metadata = metadata.mapValues { Logger.MetadataValue.string($0) }
            switch severity {
            case .warning:
                logger.warning("\(message)", metadata: metadata, source: "XcodeMCPCore")
            case .error:
                logger.error("\(message)", metadata: metadata, source: "XcodeMCPCore")
            }
        }
    }
}
