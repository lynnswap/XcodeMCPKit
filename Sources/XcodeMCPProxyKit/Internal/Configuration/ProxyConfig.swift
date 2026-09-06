import Foundation
import XcodeMCPKit
import XcodeMCPProxyRuntime

package struct ProxyConfig: Sendable {
    package enum XcodeMode: String, Sendable {
        case automatic
        case gui
        case headless
    }

    package enum UpstreamKind: Sendable {
        case stockMCPBridge
        case custom
    }

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
    package var upstreamCommand: String
    package var upstreamArgs: [String]
    package var upstreamProcessCount: Int
    package var upstreamSessionID: String?
    package var upstreamKind: UpstreamKind
    package var xcodeMode: XcodeMode
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
        upstreamCommand: String,
        upstreamArgs: [String],
        upstreamProcessCount: Int = 1,
        upstreamSessionID: String? = nil,
        upstreamKind: UpstreamKind? = nil,
        xcodeMode: XcodeMode = .automatic,
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
        self.upstreamCommand = upstreamCommand
        self.upstreamArgs = upstreamArgs
        self.upstreamProcessCount = upstreamProcessCount
        self.upstreamSessionID = upstreamSessionID
        self.upstreamKind = upstreamKind ?? Self.inferredUpstreamKind(
            command: upstreamCommand,
            arguments: upstreamArgs
        )
        self.xcodeMode = xcodeMode
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

    package func validateXcodeModeConfiguration() throws {
        guard upstreamKind == .stockMCPBridge || xcodeMode == .automatic else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                "xcodeMode must be automatic when using a custom upstream"
            )
        }
    }

    private static func inferredUpstreamKind(
        command: String,
        arguments: [String]
    ) -> UpstreamKind {
        let invocation = MCPBridgeInvocation.defaultMCPBridge
        if command == invocation.command, arguments == invocation.arguments {
            return .stockMCPBridge
        }
        return .custom
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

    package func runtimeConfiguration(
        xcodeMode: ProxyRuntimeConfiguration.XcodeMode
    ) -> ProxyRuntimeConfiguration {
        let effectiveRefreshCodeIssuesMode: ProxyRuntimeConfiguration.RefreshCodeIssuesMode
        if xcodeMode == .headless {
            // The proxy workflow resolves GUI tab identity and navigator state.
            // Headless workspace identity belongs to Xcode Service, so preserve
            // the upstream tool contract instead of manufacturing a GUI owner.
            effectiveRefreshCodeIssuesMode = .upstream
        } else {
            effectiveRefreshCodeIssuesMode = ProxyRuntimeConfiguration.RefreshCodeIssuesMode(
                refreshCodeIssuesMode
            )
        }
        return ProxyRuntimeConfiguration(
            xcodeMode: xcodeMode,
            upstreamCommand: upstreamCommand,
            upstreamArgs: upstreamArgs,
            upstreamProcessCount: upstreamProcessCount,
            upstreamSessionID: upstreamSessionID,
            maxMessageBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            prewarmToolsList: prewarmToolsList,
            usesPermissionDialogAutomation: autoApproveXcodeDialog,
            refreshCodeIssuesMode: effectiveRefreshCodeIssuesMode,
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
