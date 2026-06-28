/// Canonical raw process invocation for Xcode's MCP bridge.
package struct MCPBridgeInvocation: Equatable, Sendable {
    /// Raw process command used to launch the bridge.
    package let command: String

    /// Raw process arguments passed to the bridge command.
    package let arguments: [String]

    /// Creates a raw bridge process invocation.
    package init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    /// The canonical tool name resolved through `xcrun` for Xcode MCP.
    package static let mcpBridgeToolName = "mcpbridge"

    /// The canonical system `xcrun` path used for the default bridge launch.
    package static let xcrunCommand = "/usr/bin/xcrun"

    /// Xcode's default MCP bridge invocation.
    package static let defaultMCPBridge = Self(
        command: xcrunCommand,
        arguments: [mcpBridgeToolName]
    )
}
