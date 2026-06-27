import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

extension ProxyConfig {
    package var mcpBridgeRuntimeConfiguration: MCPBridgeRuntime.Configuration {
        MCPBridgeRuntime.Configuration(proxyConfig: self)
    }
}

extension MCPBridgeRuntime.Configuration {
    package init(proxyConfig config: ProxyConfig) {
        self.init(
            upstreamCommand: config.upstreamCommand,
            upstreamArgs: config.upstreamArgs,
            upstreamProcessCount: max(1, min(config.upstreamProcessCount, 10)),
            sharedSessionID: config.upstreamSessionID,
            maxBodyBytes: config.maxBodyBytes,
            processBoundRoutingSupported: XcrunArguments.isDefaultMCPBridgeInvocation(
                config: config
            )
        )
    }
}
