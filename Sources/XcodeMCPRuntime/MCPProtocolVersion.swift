import ProxyCore

public enum MCP {}

extension MCP {
    public enum ProtocolVersion {
        public static let current = MCPProtocolVersion.current

        public static func isSupported(_ version: String) -> Bool {
            MCPProtocolVersion.isSupported(version)
        }
    }
}
