import Foundation

/// Errors thrown by the public Xcode MCP client API.
///
/// Tool-level failures that arrive as a successful MCP `tools/call` response
/// are represented by ``MCPToolResult/isError``. This error type is used for
/// client-side validation, transport failures, protocol-shape failures,
/// timeouts, and JSON-RPC server errors.
public enum XcodeMCPError: Error, Equatable, Sendable {
    /// The client was closed before or during a request.
    case closed

    /// The client rejected a request before sending it.
    ///
    /// The associated string describes the invalid input.
    case invalidRequest(String)

    /// The server response did not match the expected MCP shape.
    ///
    /// The associated string describes the missing or invalid response field.
    case invalidResponse(String)

    /// A request exceeded the configured timeout.
    case requestTimedOut(method: String)

    /// The MCP server returned a JSON-RPC error response.
    ///
    /// `data` preserves the raw JSON-RPC error data value when the server
    /// includes one.
    case serverError(code: Int, message: String, data: MCPJSONValue?)

    /// The underlying bridge process or transport was unavailable.
    ///
    /// The associated string describes the transport failure.
    case transportUnavailable(String)

    /// The transport was replaced after an expired session, but the MCP
    /// initialize handshake could not be restored.
    case sessionRecoveryFailed(String)
}

extension XcodeMCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .closed:
            return "The Xcode MCP client is closed."
        case .invalidRequest(let reason):
            return "The Xcode MCP request is invalid: \(reason)"
        case .invalidResponse(let reason):
            return "The MCP server returned an invalid response: \(reason)"
        case .requestTimedOut(let method):
            return "The MCP request timed out: \(method)"
        case .serverError(let code, let message, _):
            return "The MCP server returned error \(code): \(message)"
        case .transportUnavailable(let reason):
            return "The Xcode MCP transport is unavailable: \(reason)"
        case .sessionRecoveryFailed(let reason):
            return "The Xcode MCP session could not be recovered: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .closed:
            return "Create a new XcodeMCP client."
        case .invalidRequest:
            return "Correct the request or client configuration and try again."
        case .invalidResponse:
            return "Verify the MCP server version and response contract."
        case .requestTimedOut:
            return "Retry with a longer request timeout if the operation is safe to repeat."
        case .serverError:
            return "Inspect the server error data and correct the request before retrying."
        case .transportUnavailable:
            return "Start Xcode or the configured proxy, then reconnect."
        case .sessionRecoveryFailed:
            return "Call reconnect() after confirming the MCP endpoint is available."
        }
    }
}
