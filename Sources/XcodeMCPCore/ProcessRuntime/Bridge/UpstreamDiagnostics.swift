import os

extension Upstream {
    /// Where an owned process session reports conditions that it handles itself, such as a
    /// dropped stdout line or a failed signal.
    package struct Diagnostics: Sendable {
        package enum Severity: Sendable {
            case warning
            case error
        }

        package var report: @Sendable (_ severity: Severity, _ message: String, _ metadata: [String: String]) -> Void

        package init(
            report: @escaping @Sendable (_ severity: Severity, _ message: String, _ metadata: [String: String]) -> Void
        ) {
            self.report = report
        }

        /// Writes to unified logging. Metadata can quote process output, so it stays private.
        package static let unifiedLog: Self = {
            let logger = Logger(subsystem: "XcodeMCPKit", category: "process")
            return Self { severity, message, metadata in
                let details = metadata.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                switch severity {
                case .warning:
                    logger.warning("\(message, privacy: .public) \(details, privacy: .private)")
                case .error:
                    logger.error("\(message, privacy: .public) \(details, privacy: .private)")
                }
            }
        }()

        func warning(_ message: String, metadata: [String: String] = [:]) {
            report(.warning, message, metadata)
        }

        func error(_ message: String, metadata: [String: String] = [:]) {
            report(.error, message, metadata)
        }
    }
}
