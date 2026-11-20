import Foundation

package struct ProxyRuntimeConfiguration: Sendable {
    package var nativeHostBundleURL: URL?
    package var developerDirectoryURL: URL?
    package var sharesCompilationCache: Bool
    package var maxMessageBytes: Int
    /// The limit for one client request, or `nil` for none.
    package var requestTimeout: Duration?
    package var prewarmToolsList: Bool

    package init(
        nativeHostBundleURL: URL? = nil,
        developerDirectoryURL: URL? = nil,
        sharesCompilationCache: Bool = false,
        maxMessageBytes: Int,
        requestTimeout: Duration?,
        prewarmToolsList: Bool = true
    ) {
        self.nativeHostBundleURL = nativeHostBundleURL
        self.developerDirectoryURL = developerDirectoryURL
        self.sharesCompilationCache = sharesCompilationCache
        self.maxMessageBytes = maxMessageBytes
        self.requestTimeout = requestTimeout
        self.prewarmToolsList = prewarmToolsList
    }
}
