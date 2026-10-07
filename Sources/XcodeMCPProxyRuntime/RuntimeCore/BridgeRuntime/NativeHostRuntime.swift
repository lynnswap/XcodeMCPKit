import XcodeMCPCore
import Foundation
import Logging

enum NativeHostRuntime {
    static func isTerminalCoreSimulatorDiagnostic(_ message: String) -> Bool {
        guard let hostFrame = message.range(
            of: #" xcode-mcp-native-host\[[0-9]+:[0-9]+\] "#,
            options: .regularExpression
        ) else { return false }
        let diagnostic = message[hostFrame.upperBound...]
        // CoreSimulator logs these fixed reasons when it invalidates its context.
        // Unknown diagnostics remain logs; their wording is not a public API contract.
        return diagnostic.hasPrefix(
            "Loaded CoreSimulatorService is no longer valid for this process.  "
                + "Simulator services will no longer be available.  Error="
        ) || diagnostic == "CoreSimulatorService connection became invalid.  Simulator services will no longer be available."
    }

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

    static func buildServiceEnvironment(
        baseEnvironment: [String: String],
        processRunner: any ProcessRunning = ProcessRunner(),
        logger: Logger = ProxyLogging.make("native-host")
    ) async throws -> [String: String] {
        let keys = [
            "SWBBUILDSERVICE_PATH", "XCBBUILDSERVICE_PATH",
            "SWBBUILDSERVICE_BUNDLE_PATH", "XCBBUILDSERVICE_BUNDLE_PATH",
        ]
        // Keep the caller's service selection ahead of launchd's, including across aliases.
        guard !keys.contains(where: { !(baseEnvironment[$0] ?? "").isEmpty }) else {
            return baseEnvironment
        }
        for key in keys {
            let output: ProcessOutput
            do {
                output = try await processRunner.run(ProcessRequest(
                    label: "launchctl getenv \(key)", executablePath: "/bin/launchctl",
                    arguments: ["getenv", key], input: nil,
                    timeoutNanoseconds: 5_000_000_000))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Cannot read launchd build service setting \(key): \(error); using inherited environment")
                return baseEnvironment
            }
            guard output.terminationStatus == 0 else {
                logger.warning("Cannot read launchd build service setting \(key): exit \(output.terminationStatus), \(output.stderr); using inherited environment")
                return baseEnvironment
            }
            var value = output.stdout
            if value.hasSuffix("\n") { value.removeLast() }
            guard !value.isEmpty else { continue }
            var environment = baseEnvironment
            environment[key] = value
            return environment
        }
        return baseEnvironment
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

    func processConfiguration(environment: [String: String]) throws -> UpstreamProcess.Config {
        try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: configuration, baseEnvironment: environment)
    }

    func startSession() async throws -> any UpstreamSession {
        let environment = try await NativeHostRuntime.buildServiceEnvironment(baseEnvironment: environment)
        return try await UpstreamProcess(configuration: processConfiguration(environment: environment)).startSession()
    }
}
