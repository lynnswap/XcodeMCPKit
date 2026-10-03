import XcodeMCPCore
import Foundation
import XcodeMCPKit
import XcodeMCPProxyRuntime

package struct ProxyConfig: Sendable {
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

    package enum File {}

    package var listenHost: String
    package var listenPort: Int
    package var nativeHostBundleURL: URL?
    package var developerDirectoryURL: URL?
    package var maxBodyBytes: Int
    package var requestTimeout: TimeInterval
    package var configPath: String?
    package var discoveryFileURL: URL?
    package var prewarmToolsList: Bool
    package var autoApproveXcodeDialog: Bool
    package var refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode
    package var disabledToolNames: Set<String>
    package var initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?

    package init(
        listenHost: String,
        listenPort: Int,
        nativeHostBundleURL: URL? = nil,
        developerDirectoryURL: URL? = nil,
        maxBodyBytes: Int,
        requestTimeout: TimeInterval,
        configPath: String? = nil,
        discoveryFileURL: URL? = nil,
        prewarmToolsList: Bool = true,
        autoApproveXcodeDialog: Bool = false,
        refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode = .proxy,
        disabledToolNames: Set<String>? = nil,
        initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride? = nil
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.nativeHostBundleURL = nativeHostBundleURL
        self.developerDirectoryURL = developerDirectoryURL
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.configPath = configPath
        self.discoveryFileURL = discoveryFileURL
        self.prewarmToolsList = prewarmToolsList
        self.autoApproveXcodeDialog = autoApproveXcodeDialog
        self.refreshCodeIssuesMode = refreshCodeIssuesMode
        self.disabledToolNames = []
        self.initializeParamsOverride = nil
        if let disabledToolNames {
            self.disabledToolNames = Self.normalizedToolNames(disabledToolNames)
        }
        if let initializeParamsOverride {
            applyInitializeParamsOverride(initializeParamsOverride)
        }
    }

    package mutating func applyFileConfiguration(_ configuration: File.LoadedConfiguration) {
        disabledToolNames = configuration.disabledToolNames
        initializeParamsOverride = configuration.initializeParamsOverride
    }

    package mutating func applyInitializeParamsOverride(
        _ override: ProxyConfig.File.InitializeHandshakeOverride
    ) {
        if let current = initializeParamsOverride {
            initializeParamsOverride = current.merging(overriding: override)
        } else if override.isEmpty == false {
            initializeParamsOverride = override
        }
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
            guard name.isEmpty == false else {
                continue
            }
            normalized.insert(name)
        }
        return normalized
    }

    package func runtimeConfiguration() -> ProxyRuntimeConfiguration {
        return ProxyRuntimeConfiguration(
            nativeHostBundleURL: nativeHostBundleURL,
            developerDirectoryURL: developerDirectoryURL,
            maxMessageBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            prewarmToolsList: prewarmToolsList,
            usesPermissionDialogAutomation: autoApproveXcodeDialog,
            refreshCodeIssuesMode: ProxyRuntimeConfiguration.RefreshCodeIssuesMode(refreshCodeIssuesMode),
            disabledToolNames: disabledToolNames,
            initializeParamsOverride: initializeParamsOverride.map(
                ProxyRuntimeConfiguration.InitializeHandshakeOverride.init
            )
        )
    }
}

private extension ProxyRuntimeConfiguration.RefreshCodeIssuesMode {
    init(_ mode: ProxyConfig.RefreshCodeIssuesMode) {
        switch mode {
        case .proxy:
            self = .proxy
        case .upstream:
            self = .upstream
        }
    }
}

private extension ProxyRuntimeConfiguration.InitializeHandshakeOverride {
    init(_ value: ProxyConfig.File.InitializeHandshakeOverride) {
        self.init(
            protocolVersion: value.protocolVersion,
            clientName: value.clientName,
            clientVersion: value.clientVersion,
            capabilities: value.capabilities?.mapValues(
                ProxyRuntimeConfiguration.JSONValue.init
            )
        )
    }
}

private extension ProxyRuntimeConfiguration.JSONValue {
    init(_ value: ProxyConfig.File.Value) {
        switch value {
        case .object(let object):
            self = .object(object.mapValues(Self.init))
        case .array(let array):
            self = .array(array.map(Self.init))
        case .string(let string):
            self = .string(string)
        case .number(.int(let number)):
            self = .number(.integer(number))
        case .number(.double(let number)):
            self = .number(.double(number))
        case .bool(let bool):
            self = .bool(bool)
        case .null:
            self = .null
        }
    }
}
