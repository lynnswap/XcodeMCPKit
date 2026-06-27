package enum MCPBridgeRuntimeError: Error, Equatable, Sendable {
    case closed
    case invalidRequest(String)
    case invalidResponse(String)
    case transportUnavailable(String)
}
