import XcodeMCPCore

extension ProxyRuntimeConfiguration {
    var nativeHostRuntimeConfiguration: NativeHostRuntime.Configuration {
        NativeHostRuntime.Configuration(proxyConfig: self)
    }
}

extension NativeHostRuntime.Configuration {
    init(proxyConfig config: ProxyRuntimeConfiguration) {
        self.init(
            nativeHostBundleURL: config.nativeHostBundleURL,
            developerDirectoryURL: config.developerDirectoryURL,
            sharesCompilationCache: config.sharesCompilationCache,
            maxBodyBytes: config.maxMessageBytes
        )
    }
}
