import Foundation
import NIOHTTP1

enum HTTPRequestValidationFailure: Error {
    case notAcceptable
    case unsupportedMediaType
}

enum HTTPRequestValidator {
    static func sessionID(from headers: HTTPHeaders) -> String? {
        headers.first(name: "Mcp-Session-Id")
    }

    static func acceptsEventStream(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return false }
        return accept.contains("text/event-stream")
    }

    static func acceptsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return true }
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
        guard wantsEventStream || wantsJSON else {
            throw HTTPRequestValidationFailure.notAcceptable
        }
        guard contentTypeIsJSON(headers) else {
            throw HTTPRequestValidationFailure.unsupportedMediaType
        }
        // Prefer JSON when both are acceptable.
        return wantsEventStream && !wantsJSON
    }
}
