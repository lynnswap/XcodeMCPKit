import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime

extension XcrunArguments {
    /// Whether the configured upstream is the stock `xcrun ... mcpbridge`
    /// invocation, which is what the Xcode-specific readiness gating and
    /// the documentation provider key their availability on.
    static func isDefaultMCPBridgeInvocation(config: ProxyConfig) -> Bool {
        guard isXcrunCommand(config.upstreamCommand),
              let toolName = firstToolSelection(from: config.upstreamArgs)?.toolName
        else {
            return false
        }
        return URL(fileURLWithPath: toolName).lastPathComponent == MCPBridgeInvocation.mcpBridgeToolName
    }
}
