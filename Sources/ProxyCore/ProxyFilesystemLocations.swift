import Foundation

public enum ProxyFilesystemLocations {
    public static let cacheRootEnv = "XCODE_MCP_PROXY_CACHE_ROOT"
    public static let discoveryFileEnv = "XCODE_MCP_PROXY_DISCOVERY_FILE"

    public static func discoveryFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let overridePath = nonEmpty(environment[discoveryFileEnv]) {
            return URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath)
        }

        let cacheRootURL: URL
        if let overrideRoot = nonEmpty(environment[cacheRootEnv]) {
            cacheRootURL = URL(
                fileURLWithPath: NSString(string: overrideRoot).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            let defaultRoot =
                fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            cacheRootURL = defaultRoot
        }

        return cacheRootURL
            .appendingPathComponent("XcodeMCPProxy", isDirectory: true)
            .appendingPathComponent("endpoint.json")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
