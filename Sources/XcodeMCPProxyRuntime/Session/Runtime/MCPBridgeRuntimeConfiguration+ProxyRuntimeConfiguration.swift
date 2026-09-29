import XcodeMCPCore

extension ProxyRuntimeConfiguration {
    var mcpBridgeRuntimeConfiguration: MCPBridgeRuntime.Configuration {
        MCPBridgeRuntime.Configuration(proxyConfig: self)
    }
}

extension MCPBridgeRuntime.Configuration {
    init(proxyConfig config: ProxyRuntimeConfiguration) {
        self.init(
            upstreamProcessCount: max(1, min(config.upstreamProcessCount, 10)),
            maxBodyBytes: config.maxMessageBytes,
            includesServiceBackend: config.includesXcodeService
        )
    }
}
