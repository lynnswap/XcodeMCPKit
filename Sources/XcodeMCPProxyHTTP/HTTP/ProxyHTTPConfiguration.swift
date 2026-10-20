package struct ProxyHTTPConfiguration: Sendable {
    package let listenHost: String
    package let listenPort: Int
    package let maxBodyBytes: Int
    /// Serves `/debug/upstreams` and `/debug/reset` on a loopback listener.
    package let enablesDebugEndpoints: Bool

    package init(listenHost: String, listenPort: Int, maxBodyBytes: Int, enablesDebugEndpoints: Bool = false) {
        precondition(listenHost.isEmpty == false, "HTTP listen host must not be empty")
        precondition((0...65_535).contains(listenPort), "HTTP listen port is out of range")
        precondition(maxBodyBytes > 0, "HTTP body limit must be positive")
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.maxBodyBytes = maxBodyBytes
        self.enablesDebugEndpoints = enablesDebugEndpoints
    }
}
