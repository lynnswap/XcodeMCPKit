import Darwin
import Foundation

extension XcodeMCPProxyServer {
    /// Diagnostic error for a listen port already owned by another process.
    public struct PortInUseError: Error, CustomStringConvertible, Equatable, Sendable {
        /// Requested listen host.
        public let host: String

        /// Requested listen port.
        public let port: Int

        /// Detected `xcode-mcp-proxy-server` process identifiers.
        public let processIdentifiers: [Int]

        /// Creates a port-in-use diagnostic.
        public init(host: String, port: Int, processIdentifiers: [Int] = []) {
            self.host = host
            self.port = port
            self.processIdentifiers = processIdentifiers
        }

        /// User-facing diagnostic message.
        public var description: String {
            let displayHost: String = {
                if host.contains(":"), !host.hasPrefix("[") {
                    return "[\(host)]"
                }
                return host
            }()

            var lines: [String] = []
            lines.reserveCapacity(8)
            lines.append("error: listen \(displayHost):\(port) is already in use (Address already in use).")
            if processIdentifiers.count == 1 {
                lines.append("Detected a running xcode-mcp-proxy-server (pid: \(processIdentifiers[0])).")
            } else if processIdentifiers.count > 1 {
                let formatted = processIdentifiers.map(String.init).joined(separator: ", ")
                lines.append("Detected running xcode-mcp-proxy-server processes (pids: \(formatted)).")
            }
            lines.append("Terminate the existing process and try again.")
            lines.append(
                "To force a restart, rerun with `--force-restart`; this will terminate the existing xcode-mcp-proxy-server and start a new one."
            )
            lines.append("")
            lines.append("Examples:")
            lines.append("  pkill -x xcode-mcp-proxy-server")
            lines.append("  xcode-mcp-proxy-server --force-restart")
            return lines.joined(separator: "\n")
        }
    }

    package static func isAddressAlreadyInUse(_ error: Swift.Error) -> Bool {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("Address already in use") {
            return true
        }
        return text.contains("errno: \(EADDRINUSE)")
    }
}
