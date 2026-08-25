import XcodeMCPKit

extension ProxyRuntimeConfiguration {
    var mcpBridgeRuntimeConfiguration: MCPBridgeRuntime.Configuration {
        MCPBridgeRuntime.Configuration(proxyConfig: self)
    }
}

extension MCPBridgeRuntime.Configuration {
    init(proxyConfig config: ProxyRuntimeConfiguration) {
        self.init(
            upstreamCommand: config.upstreamCommand,
            upstreamArgs: config.upstreamArgs,
            upstreamProcessCount: max(1, min(config.upstreamProcessCount, 10)),
            sharedSessionID: config.upstreamSessionID,
            maxBodyBytes: config.maxMessageBytes,
            processBoundRoutingSupported: config.xcodeMode == .gui
                && XcrunArguments.isDefaultMCPBridgeInvocation(config: config),
            removesInheritedXcodeProcessBinding: config.xcodeMode == .headless
        )
    }
}
