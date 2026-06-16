public enum MCPProtocolVersion {
    public static let current = "2025-06-18"

    public static func isSupported(_ version: String) -> Bool {
        version == current
    }
}
