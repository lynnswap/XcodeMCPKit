import Foundation

public enum XcodeMCPError: Error, Equatable, Sendable {
    case closed
    case invalidRequest(String)
    case invalidResponse(String)
    case requestTimedOut(method: String)
    case serverError(code: Int, message: String, data: MCPJSONValue?)
    case transportUnavailable(String)
}
