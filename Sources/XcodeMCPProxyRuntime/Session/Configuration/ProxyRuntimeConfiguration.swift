import Foundation
import XcodeMCPCore

package struct ProxyRuntimeConfiguration: Sendable {
    package enum ValidationError: Error, CustomStringConvertible {
        case unsupportedProtocolVersion(String)

        package var description: String {
            switch self {
            case .unsupportedProtocolVersion(let protocolVersion):
                return
                    "initializeHandshake.protocolVersion must be \(MCPProtocolVersion.current); "
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

    package var nativeHostBundleURL: URL?
    package var developerDirectoryURL: URL?
    package var maxMessageBytes: Int
    package var requestTimeout: TimeInterval
    package var prewarmToolsList: Bool
    package var usesPermissionDialogAutomation: Bool
    package var initializeParamsOverride: InitializeHandshakeOverride?

    package init(
        nativeHostBundleURL: URL? = nil,
        developerDirectoryURL: URL? = nil,
        maxMessageBytes: Int,
        requestTimeout: TimeInterval,
        prewarmToolsList: Bool = true,
        usesPermissionDialogAutomation: Bool = false,
        initializeParamsOverride: InitializeHandshakeOverride? = nil
    ) {
        self.nativeHostBundleURL = nativeHostBundleURL
        self.developerDirectoryURL = developerDirectoryURL
        self.maxMessageBytes = maxMessageBytes
        self.requestTimeout = requestTimeout
        self.prewarmToolsList = prewarmToolsList
        self.usesPermissionDialogAutomation = usesPermissionDialogAutomation
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
}
