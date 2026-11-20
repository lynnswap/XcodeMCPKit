/// Raw invocation of a configured MCP process.
package struct MCPProcessInvocation: Equatable, Sendable {
    /// Raw process command used to launch the process.
    package let command: String

    /// Raw process arguments passed to the command.
    package let arguments: [String]

    /// Creates a raw process invocation.
    package init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

}
