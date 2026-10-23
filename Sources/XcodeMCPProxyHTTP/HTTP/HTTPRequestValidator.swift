import Foundation
import NIOHTTP1
import XcodeMCPCore

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

    /// A browser cannot send this content type across origins without asking first.
    static func contentTypeIsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let contentType = headers.first(name: "Content-Type")?.lowercased() else { return false }
        return contentType.hasPrefix("application/json")
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
