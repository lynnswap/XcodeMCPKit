import Foundation
import XcodeMCPRuntime

extension XcrunArguments {
    /// Whether the configured upstream is the stock `xcrun ... mcpbridge`
    /// invocation, which is what the Xcode-specific readiness gating and
    /// the documentation provider key their availability on.
    package static func isDefaultMCPBridgeInvocation(config: ProxyConfig) -> Bool {
        guard isXcrunCommand(config.upstreamCommand),
              let toolName = firstToolSelection(from: config.upstreamArgs)?.toolName
        else {
            return false
        }
        return URL(fileURLWithPath: toolName).lastPathComponent == "mcpbridge"
    }
}
