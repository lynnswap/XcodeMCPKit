public enum MCP {}

package enum MCPProtocolVersion {
    package static let current = "2025-06-18"

    package static func isSupported(_ version: String) -> Bool {
        version == current
    }
}

extension MCP {
    public enum ProtocolVersion {
        public static let current = MCPProtocolVersion.current

        public static func isSupported(_ version: String) -> Bool {
            MCPProtocolVersion.isSupported(version)
        }
    }
}
