package enum MCPBridgeRuntimeError: Error, Equatable, Sendable {
    case closed
    case invalidRequest(String)
    case invalidResponse(String)
    case requestTimedOut(method: String)
    case serverError(code: Int, message: String, data: JSONValue?)
    case httpStatus(code: Int, body: String)
    case transportUnavailable(String)
}
