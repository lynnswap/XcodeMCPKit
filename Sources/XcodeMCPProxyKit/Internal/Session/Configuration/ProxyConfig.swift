import Foundation
import XcodeMCPKit

struct ProxyConfig: Sendable {
    enum Transport: String, CaseIterable, Sendable {
        case http
        case stdio
    }

    enum StdioUpstreamSource: String, Sendable {
        case explicit
        case environment
        case discovery
        case fallback
    }

    enum RefreshCodeIssuesMode: String, Sendable {
        case proxy
        case upstream
    }

    enum ValidationError: Error, CustomStringConvertible {
        case unsupportedProtocolVersion(String)

        var description: String {
            switch self {
            case .unsupportedProtocolVersion(let protocolVersion):
                return "upstream_handshake.protocolVersion must be \(MCPProtocolVersion.current); \(protocolVersion) is not supported"
            }
        }
    }

    enum File {}

    var listenHost: String
    var listenPort: Int
    var upstreamCommand: String
    var upstreamArgs: [String]
    var upstreamProcessCount: Int
    var upstreamSessionID: String?
    var maxBodyBytes: Int
    var requestTimeout: TimeInterval
    var configPath: String?
    var transport: ProxyConfig.Transport
    var stdioUpstreamURL: URL?
    var stdioUpstreamSource: ProxyConfig.StdioUpstreamSource?
    var discoveryFileURL: URL?
    var prewarmToolsList: Bool
    var autoApproveXcodeDialog: Bool
    var refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode
    var disabledToolNames: Set<String>
    var initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?

    init(
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
        disabledToolNames: Set<String>? = nil,
        initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride? = nil
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
        self.disabledToolNames = []
        self.initializeParamsOverride = nil
        if let disabledToolNames {
            self.disabledToolNames = Self.normalizedToolNames(disabledToolNames)
        }
        if let initializeParamsOverride {
            applyInitializeParamsOverride(initializeParamsOverride)
        }
    }

    mutating func applyFileConfiguration(_ configuration: File.LoadedConfiguration) {
        disabledToolNames = configuration.disabledToolNames
        initializeParamsOverride = configuration.initializeParamsOverride
    }

    mutating func applyInitializeParamsOverride(
        _ override: ProxyConfig.File.InitializeHandshakeOverride
    ) {
        if let current = initializeParamsOverride {
            initializeParamsOverride = current.merging(overriding: override)
        } else if override.isEmpty == false {
            initializeParamsOverride = override
        }
    }

    func validateModernProtocolConfiguration() throws {
        guard let protocolVersion = initializeParamsOverride?.protocolVersion else {
            return
        }
        guard MCPProtocolVersion.isSupported(protocolVersion) else {
            throw ValidationError.unsupportedProtocolVersion(protocolVersion)
        }
    }

    static func normalizedToolNames<S: Sequence>(_ names: S) -> Set<String>
        where S.Element == String
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
}
