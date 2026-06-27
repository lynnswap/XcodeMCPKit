package enum MCPProtocolVersion {
    package static let current = "2025-06-18"

    package static func isSupported(_ version: String) -> Bool {
        version == current
    }
}
