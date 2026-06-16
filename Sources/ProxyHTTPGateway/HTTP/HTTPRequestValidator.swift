import Foundation
import NIOHTTP1

enum HTTPRequestValidationFailure: Error {
    case notAcceptable
    case unsupportedMediaType
}

enum HTTPRequestValidator {
    static let sessionHeader = "MCP-Session-Id"
    static let protocolVersionHeader = "MCP-Protocol-Version"

    static func sessionID(from headers: HTTPHeaders) -> String? {
        headers.first(name: sessionHeader)
    }

    static func protocolVersion(from headers: HTTPHeaders) -> String? {
        headers.first(name: protocolVersionHeader)
    }

    static func acceptsEventStream(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return false }
        return accept.contains("text/event-stream")
    }

    static func acceptsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return false }
        return accept.contains("application/json") || accept.contains("*/*")
    }

    static func contentTypeIsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let contentType = headers.first(name: "Content-Type")?.lowercased() else { return false }
        return contentType.hasPrefix("application/json")
    }

    static func postPreference(
        for headers: HTTPHeaders
    ) throws -> Bool {
        let wantsEventStream = acceptsEventStream(headers)
        let wantsJSON = acceptsJSON(headers)
        guard wantsEventStream && wantsJSON else {
            throw HTTPRequestValidationFailure.notAcceptable
        }
        guard contentTypeIsJSON(headers) else {
            throw HTTPRequestValidationFailure.unsupportedMediaType
        }
        // The gateway currently chooses JSON responses for single POST replies.
        return false
    }
}
