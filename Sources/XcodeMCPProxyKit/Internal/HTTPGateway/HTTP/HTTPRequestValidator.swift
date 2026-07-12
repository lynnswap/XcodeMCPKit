import Foundation
import NIOHTTP1
import XcodeMCPKit

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

    static func acceptsEventStream(_ headers: HTTPHeaders) -> Bool {
        let accept = combinedHeaderValue(name: "Accept", from: headers).lowercased()
        guard accept.isEmpty == false else { return false }
        return accept.contains("text/event-stream")
    }

    static func acceptsJSON(_ headers: HTTPHeaders) -> Bool {
        let accept = combinedHeaderValue(name: "Accept", from: headers).lowercased()
        guard accept.isEmpty == false else { return false }
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

    private static func combinedHeaderValue(name: String, from headers: HTTPHeaders) -> String {
        headers
            .filter { header in
                header.name.compare(name, options: .caseInsensitive) == .orderedSame
            }
            .map(\.value)
            .joined(separator: ",")
    }
}

enum HTTPRequestProtocolVersionResolver {
    enum Resolution: Equatable, Sendable {
        case accepted(String)
        case rejected
    }

    static let specificationDefault = "2025-03-26"

    static func resolve(
        headers: HTTPHeaders,
        negotiatedVersion: String?
    ) -> Resolution {
        let expectedVersion = negotiatedVersion ?? specificationDefault
        guard MCP.ProtocolVersion.isSupported(expectedVersion) else {
            return .rejected
        }

        let explicitVersions = headers[HTTPRequestValidator.protocolVersionHeader]
        guard explicitVersions.count <= 1 else {
            return .rejected
        }
        guard let explicitVersion = explicitVersions.first else {
            return .accepted(expectedVersion)
        }
        guard explicitVersion.isEmpty == false,
            MCP.ProtocolVersion.isSupported(explicitVersion),
            explicitVersion == expectedVersion
        else {
            return .rejected
        }
        return .accepted(explicitVersion)
    }
}
