package enum MCP {}

package enum MCPProtocolVersion {
    package static let current = "2025-06-18"

    package static func isSupported(_ version: String) -> Bool {
        version == current
    }
}

extension MCP {
    package enum ProtocolVersion {
        package static let current = MCPProtocolVersion.current

        package static func isSupported(_ version: String) -> Bool {
            MCPProtocolVersion.isSupported(version)
        }
    }
}
