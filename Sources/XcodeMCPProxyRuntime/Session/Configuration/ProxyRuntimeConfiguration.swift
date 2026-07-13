import Foundation
import XcodeMCPKit

package struct ProxyRuntimeConfiguration: Sendable {
    package enum RefreshCodeIssuesMode: String, Sendable {
        case proxy
        case upstream
    }

    package enum ValidationError: Error, CustomStringConvertible {
        case unsupportedProtocolVersion(String)

        package var description: String {
            switch self {
            case .unsupportedProtocolVersion(let protocolVersion):
                return
                    "upstream_handshake.protocolVersion must be \(MCPProtocolVersion.current); "
                    + "\(protocolVersion) is not supported"
            }
        }
    }

    package indirect enum JSONValue: Equatable, Sendable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Number)
        case bool(Bool)
        case null
    }

    package enum Number: Equatable, Sendable {
        case integer(Int64)
        case double(Double)
    }

    package struct InitializeHandshakeOverride: Equatable, Sendable {
        package var protocolVersion: String?
        package var clientName: String?
        package var clientVersion: String?
        package var capabilities: [String: JSONValue]?

        package init(
            protocolVersion: String? = nil,
            clientName: String? = nil,
            clientVersion: String? = nil,
            capabilities: [String: JSONValue]? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
        }

        package var isEmpty: Bool {
            protocolVersion == nil
                && clientName == nil
                && clientVersion == nil
                && capabilities == nil
        }
    }

    package var upstreamCommand: String
    package var upstreamArgs: [String]
    package var upstreamProcessCount: Int
    package var upstreamSessionID: String?
    package var maxMessageBytes: Int
    package var requestTimeout: TimeInterval
    package var prewarmToolsList: Bool
    package var usesPermissionDialogAutomation: Bool
    package var refreshCodeIssuesMode: RefreshCodeIssuesMode
    package var disabledToolNames: Set<String>
    package var initializeParamsOverride: InitializeHandshakeOverride?

    package init(
        upstreamCommand: String,
        upstreamArgs: [String],
        upstreamProcessCount: Int = 1,
        upstreamSessionID: String? = nil,
        maxMessageBytes: Int,
        requestTimeout: TimeInterval,
        prewarmToolsList: Bool = true,
        usesPermissionDialogAutomation: Bool = false,
        refreshCodeIssuesMode: RefreshCodeIssuesMode = .proxy,
        disabledToolNames: Set<String> = [],
        initializeParamsOverride: InitializeHandshakeOverride? = nil
    ) {
        self.upstreamCommand = upstreamCommand
        self.upstreamArgs = upstreamArgs
        self.upstreamProcessCount = upstreamProcessCount
        self.upstreamSessionID = upstreamSessionID
        self.maxMessageBytes = maxMessageBytes
        self.requestTimeout = requestTimeout
        self.prewarmToolsList = prewarmToolsList
        self.usesPermissionDialogAutomation = usesPermissionDialogAutomation
        self.refreshCodeIssuesMode = refreshCodeIssuesMode
        self.disabledToolNames = Self.normalizedToolNames(disabledToolNames)
        self.initializeParamsOverride = initializeParamsOverride
    }

    package func validateModernProtocolConfiguration() throws {
        guard let protocolVersion = initializeParamsOverride?.protocolVersion else {
            return
        }
        guard MCPProtocolVersion.isSupported(protocolVersion) else {
            throw ValidationError.unsupportedProtocolVersion(protocolVersion)
        }
    }

    static func normalizedToolNames<S: Sequence>(_ names: S) -> Set<String>
    where
        S.Element == String
    {
        var normalized = Set<String>()
        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { continue }
            normalized.insert(name)
        }
        return normalized
    }
}
