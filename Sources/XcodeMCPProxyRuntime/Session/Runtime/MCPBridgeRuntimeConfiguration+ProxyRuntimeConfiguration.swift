import XcodeMCPCore

extension ProxyRuntimeConfiguration {
    var mcpBridgeRuntimeConfiguration: MCPBridgeRuntime.Configuration {
        MCPBridgeRuntime.Configuration(proxyConfig: self)
    }
}

extension MCPBridgeRuntime.Configuration {
    init(proxyConfig config: ProxyRuntimeConfiguration) {
        self.init(
            nativeHostBundleURL: config.nativeHostBundleURL,
            developerDirectoryURL: config.developerDirectoryURL,
            maxBodyBytes: config.maxMessageBytes
        )
    }
}
