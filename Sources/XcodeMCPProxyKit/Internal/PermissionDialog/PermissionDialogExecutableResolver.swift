import XcodeMCPCore

/// Executables used by native Service bridges; GUI bridge paths come from process inventory.
enum PermissionDialogExecutableResolver {
    static func additionalExecutableCandidates(
        executableLookupClient: ExecutableLookupClient = .liveValue
    ) -> [String] {
        let invocation = MCPBridgeInvocation.defaultMCPBridge
        let command = executableLookupClient.resolveExecutablePath(invocation.command) ?? invocation.command
        let bridge = executableLookupClient.resolveXcrunToolPath(command, MCPBridgeInvocation.mcpBridgeToolName, [])
        return [command] + (bridge.map { [$0] } ?? [])
    }
}
