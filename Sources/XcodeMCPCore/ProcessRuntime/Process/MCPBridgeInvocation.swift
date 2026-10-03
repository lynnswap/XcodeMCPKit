/// Raw invocation of a configured MCP process.
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

}
