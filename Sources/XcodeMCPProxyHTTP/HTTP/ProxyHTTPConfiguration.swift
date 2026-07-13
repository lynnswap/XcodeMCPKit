package struct ProxyHTTPConfiguration: Sendable {
    package let listenHost: String
    package let listenPort: Int
    package let maxBodyBytes: Int

    package init(listenHost: String, listenPort: Int, maxBodyBytes: Int) {
        precondition(listenHost.isEmpty == false, "HTTP listen host must not be empty")
        precondition((0...65_535).contains(listenPort), "HTTP listen port is out of range")
        precondition(maxBodyBytes > 0, "HTTP body limit must be positive")
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.maxBodyBytes = maxBodyBytes
    }
}
