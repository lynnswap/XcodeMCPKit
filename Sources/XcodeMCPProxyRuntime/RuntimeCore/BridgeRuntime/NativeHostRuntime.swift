import XcodeMCPCore
import Foundation

enum NativeHostRuntime {
    struct Configuration: Sendable {
        let nativeHostBundleURL: URL?
        let developerDirectoryURL: URL?
        let maxBodyBytes: Int

        init(nativeHostBundleURL: URL? = nil, developerDirectoryURL: URL? = nil, maxBodyBytes: Int) {
            self.nativeHostBundleURL = nativeHostBundleURL
            self.developerDirectoryURL = developerDirectoryURL
            self.maxBodyBytes = maxBodyBytes
        }
    }

    static func makeUpstreamSlot(
        config: Configuration,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ManagedUpstreamSlot {
        ManagedUpstreamSlot(factory: NativeHostSessionFactory(
            configuration: config, environment: baseEnvironment))
    }

    static func makeDefaultUpstreamConfig(
        config: Configuration,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> UpstreamProcess.Config {
        var environment = baseEnvironment
        environment.removeValue(forKey: "XCODE_PID")
        environment.removeValue(forKey: "MCP_XCODE_PID")
        environment.removeValue(forKey: "MCP_XCODE_SESSION_ID")
        let developerDirectoryURL = config.developerDirectoryURL
        let invocation = try NativeHostInvocation.resolve(
            bundleURL: config.nativeHostBundleURL,
            developerDirectoryURL: developerDirectoryURL,
            environment: environment)
        if let developerDirectoryURL { environment["DEVELOPER_DIR"] = developerDirectoryURL.path }
        let messageLimit = maxQueuedWriteBytes(for: config)
        return UpstreamProcess.Config(
            command: invocation.command,
            args: invocation.arguments + ["--max-message-bytes", String(messageLimit)],
            environment: environment,
            maxQueuedWriteBytes: messageLimit)
    }

    private static func maxQueuedWriteBytes(for config: Configuration) -> Int {
        let minimum = 1_048_576
        guard config.maxBodyBytes > 0 else { return minimum }
        let multiplied = config.maxBodyBytes.multipliedReportingOverflow(by: 4)
        if multiplied.overflow {
            return Int.max
        }
        return max(minimum, multiplied.partialValue)
    }

}

struct NativeHostSessionFactory: UpstreamSessionFactory {
    let configuration: NativeHostRuntime.Configuration
    let environment: [String: String]

    func processConfiguration() throws -> UpstreamProcess.Config {
        try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: configuration, baseEnvironment: environment)
    }

    func startSession() async throws -> any UpstreamSession {
        try await UpstreamProcess(configuration: processConfiguration()).startSession()
    }
}
