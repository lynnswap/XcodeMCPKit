import Foundation
import XcodeMCPRuntime

package struct ProxyConfig: Sendable {
    package enum Transport: String, CaseIterable, Sendable {
        case http
        case stdio
    }

    package enum StdioUpstreamSource: String, Sendable {
        case explicit
        case environment
        case discovery
        case fallback
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
                return "upstream_handshake.protocolVersion must be \(MCPProtocolVersion.current); \(protocolVersion) is not supported"
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
    package var maxBodyBytes: Int
    package var requestTimeout: TimeInterval
    package var configPath: String?
    package var transport: ProxyConfig.Transport
    package var stdioUpstreamURL: URL?
    package var stdioUpstreamSource: ProxyConfig.StdioUpstreamSource?
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
        maxBodyBytes: Int,
        requestTimeout: TimeInterval,
        configPath: String? = nil,
        transport: ProxyConfig.Transport = .http,
        stdioUpstreamURL: URL? = nil,
        stdioUpstreamSource: ProxyConfig.StdioUpstreamSource? = nil,
        discoveryFileURL: URL? = nil,
        prewarmToolsList: Bool = true,
        autoApproveXcodeDialog: Bool = false,
        refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode = .proxy,
        disabledToolNames: Set<String>? = nil
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamCommand = upstreamCommand
        self.upstreamArgs = upstreamArgs
        self.upstreamProcessCount = upstreamProcessCount
        self.upstreamSessionID = upstreamSessionID
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.configPath = configPath
        self.transport = transport
        self.stdioUpstreamURL = stdioUpstreamURL
        self.stdioUpstreamSource = stdioUpstreamSource
        self.discoveryFileURL = discoveryFileURL
        self.prewarmToolsList = prewarmToolsList
        self.autoApproveXcodeDialog = autoApproveXcodeDialog
        self.refreshCodeIssuesMode = refreshCodeIssuesMode
        self.disabledToolNames = disabledToolNames ?? []
        if configPath != nil {
            loadFileConfig(preserveDisabledToolNames: disabledToolNames != nil)
        }
    }

    /// Reads the TOML file config (disabled tools, initialize-params
    /// override) from `configPath` and stores the decoded values. This is
    /// the only place the file is read; consumers use the stored values.
    package mutating func loadFileConfig() {
        loadFileConfig(preserveDisabledToolNames: false)
    }

    private mutating func loadFileConfig(preserveDisabledToolNames: Bool) {
        let logger = ProxyLogging.make("config")
        if preserveDisabledToolNames == false {
            disabledToolNames = ProxyConfig.File.Loader.loadDisabledToolNames(
                configPath: configPath,
                logger: logger
            )
        }
        initializeParamsOverride = ProxyConfig.File.Loader.loadInitializeParamsOverride(
            configPath: configPath,
            logger: logger
        )
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
