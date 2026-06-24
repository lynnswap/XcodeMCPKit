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
}
