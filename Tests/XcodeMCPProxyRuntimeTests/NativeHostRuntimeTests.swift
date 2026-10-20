@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct NativeHostRuntimeTests {
    private static let terminalCoreSimulatorDiagnostic =
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61 \"Connection refused\""

    @Test(arguments: [
        terminalCoreSimulatorDiagnostic,
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] CoreSimulatorService connection became invalid.  Simulator services will no longer be available.",
    ])
    func terminalCoreSimulatorDiagnosticsIdentifyAnUnusableNativeHost(message: String) {
        #expect(NativeHostRuntime.isTerminalCoreSimulatorDiagnostic(message))
    }

    @Test(arguments: [
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] CoreSimulatorService connection was interrupted.",
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] Error Domain=NSPOSIXErrorDomain Code=61 \"Connection refused\"",
        "[-[SimLaunchHostConnection _connectToServiceName:]_block_invoke:250] ERROR : Lost connection to com.apple.CoreSimulator.SimLaunchHost-arm64",
        "Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61",
        "2026-10-05 23:53:55.624 xcodebuild[43311:36380528] Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61",
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] xcodebuild output: Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61",
    ])
    func otherSimulatorDiagnosticsDoNotRequireNativeHostReplacement(message: String) {
        #expect(!NativeHostRuntime.isTerminalCoreSimulatorDiagnostic(message))
    }

    @Test func guiTargetConnectsUsingItsOwnBridgeAndPID() throws {
        var runtime = try makeBridgeRuntimeConfig(makeConfig(requestTimeout: 5))
        runtime = NativeHostRuntime.Configuration(nativeHostBundleURL: runtime.nativeHostBundleURL,
            guiProcess: XcodeGUIProcess(processID: 2468, launchDate: Date(timeIntervalSince1970: 100),
                installation: XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/GUI.app"))),
            maxBodyBytes: runtime.maxBodyBytes)
        let configuration = try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: runtime,
            baseEnvironment: ["MCP_XCODE_PID": "old", "MCP_XCODE_SESSION_ID": "old-session",
                              "XCODE_PID": "old", "PATH": "/usr/bin"])
        #expect(configuration.command == "/Fixture/GUI.app/Contents/Developer/usr/bin/mcpbridge")
        #expect(configuration.args.isEmpty)
        #expect(configuration.environment["MCP_XCODE_PID"] == "2468")
        #expect(configuration.environment["DEVELOPER_DIR"] == "/Fixture/GUI.app/Contents/Developer")
        #expect(configuration.environment["MCP_XCODE_SESSION_ID"] == nil)
        #expect(configuration.environment["XCODE_PID"] == nil)
    }

    @Test func nativeHostIgnoresInheritedGUIRoutingConfiguration() throws {
        let configuration = try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 5)),
            baseEnvironment: ["MCP_XCODE_PID": "9876", "MCP_XCODE_SESSION_ID": "parent-session",
                "XCODE_PID": "legacy", "DEVELOPER_DIR": "/Parent/Developer", "PATH": "/usr/bin"])
        #expect(configuration.environment["MCP_XCODE_PID"] == nil)
        #expect(configuration.environment["MCP_XCODE_SESSION_ID"] == nil)
        #expect(configuration.environment["XCODE_PID"] == nil)
        #expect(configuration.environment["DEVELOPER_DIR"] == "/Parent/Developer")
        #expect(configuration.environment["PATH"] == "/usr/bin")
        #expect(!configuration.args.contains("--share-compilation-cache"))
    }

    @Test(arguments: [false, true])
    func compilationCacheSharingReachesTheOwnedHost(sharesCompilationCache: Bool) throws {
        var config = makeConfig(requestTimeout: 5)
        config.sharesCompilationCache = sharesCompilationCache
        let configuration = try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: makeBridgeRuntimeConfig(config), baseEnvironment: [:])

        #expect(configuration.args.contains("--share-compilation-cache") == sharesCompilationCache)
    }

    @Test func launchdBuildServicePathReachesNativeHostConfiguration() async throws {
        let path = "/Users/Test User/Custom Build/SWBBuildServiceBundle "
        let runner = BuildServiceEnvironmentProcessRunner(outputs: [
            "XCBBUILDSERVICE_PATH": ProcessOutput(
                terminationStatus: 0, stdout: path + "\n", stderr: ""),
            "SWBBUILDSERVICE_BUNDLE_PATH": ProcessOutput(
                terminationStatus: 0, stdout: "/Another/Service.bundle\n", stderr: ""),
        ])
        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: ["PATH": "/usr/bin", "MCP_XCODE_PID": "9876"],
            processRunner: runner)
        let configuration = try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 5)),
            baseEnvironment: environment)

        #expect(configuration.environment["XCBBUILDSERVICE_PATH"] == path)
        #expect(configuration.environment["PATH"] == "/usr/bin")
        #expect(configuration.environment["MCP_XCODE_PID"] == nil)
        #expect(configuration.environment["SWBBUILDSERVICE_BUNDLE_PATH"] == nil)
        #expect(await runner.requests().map(\.arguments) == [
            ["getenv", "SWBBUILDSERVICE_PATH"],
            ["getenv", "XCBBUILDSERVICE_PATH"],
        ])
    }

    @Test(arguments: [
        "SWBBUILDSERVICE_PATH", "XCBBUILDSERVICE_PATH",
        "SWBBUILDSERVICE_BUNDLE_PATH", "XCBBUILDSERVICE_BUNDLE_PATH",
    ])
    func explicitBuildServiceEnvironmentOverridesLaunchdAcrossAliases(key: String) async throws {
        let baseEnvironment = [key: "/Explicit/Service", "PATH": "/usr/bin"]
        let runner = BuildServiceEnvironmentProcessRunner(outputs: [
            "SWBBUILDSERVICE_PATH": ProcessOutput(
                terminationStatus: 0, stdout: "/Global/Service\n", stderr: ""),
        ])

        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: baseEnvironment, processRunner: runner)

        #expect(environment == baseEnvironment)
        #expect(await runner.requests().isEmpty)
    }

    @Test func emptyInheritedBuildServicePathAllowsLaunchdSelection() async throws {
        let runner = BuildServiceEnvironmentProcessRunner(outputs: [
            "SWBBUILDSERVICE_PATH": ProcessOutput(
                terminationStatus: 0, stdout: "/Global/Service\n", stderr: ""),
            "XCBBUILDSERVICE_PATH": ProcessOutput(
                terminationStatus: 0, stdout: "/LowerPriority/Service\n", stderr: ""),
        ])

        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: ["XCBBUILDSERVICE_PATH": ""], processRunner: runner)

        #expect(environment["SWBBUILDSERVICE_PATH"] == "/Global/Service")
        #expect(environment["XCBBUILDSERVICE_PATH"] == "")
        #expect(await runner.requests().count == 1)
    }

    @Test(arguments: ["SWBBUILDSERVICE_BUNDLE_PATH", "XCBBUILDSERVICE_BUNDLE_PATH"])
    func launchdBuildServiceBundleSelectionIsInherited(key: String) async throws {
        let runner = BuildServiceEnvironmentProcessRunner(outputs: [
            key: ProcessOutput(
                terminationStatus: 0, stdout: "/Global/Service.bundle\n", stderr: ""),
        ])

        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: ["PATH": "/usr/bin"], processRunner: runner)

        #expect(environment[key] == "/Global/Service.bundle")
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test func unsetLaunchdBuildServiceEnvironmentPreservesInheritedEnvironment() async throws {
        let baseEnvironment = ["PATH": "/usr/bin", "DEVELOPER_DIR": "/Parent/Developer"]
        let runner = BuildServiceEnvironmentProcessRunner()

        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: baseEnvironment, processRunner: runner)

        #expect(environment == baseEnvironment)
        #expect(await runner.requests().count == 4)
    }

    @Test func failedLaunchdBuildServiceLookupPreservesInheritedEnvironment() async throws {
        let baseEnvironment = ["PATH": "/usr/bin"]
        let runner = BuildServiceEnvironmentProcessRunner(outputs: [
            "SWBBUILDSERVICE_PATH": ProcessOutput(
                terminationStatus: 5, stdout: "/Unusable/Service\n", stderr: "lookup failed"),
        ])

        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: baseEnvironment, processRunner: runner)

        #expect(environment == baseEnvironment)
        #expect(await runner.requests().count == 1)
    }

    @Test func launchdBuildServiceLookupLaunchFailurePreservesInheritedEnvironment() async throws {
        let baseEnvironment = ["PATH": "/usr/bin"]
        let runner = BuildServiceEnvironmentProcessRunner(failure: .launchFailed)

        let environment = try await NativeHostRuntime.buildServiceEnvironment(
            baseEnvironment: baseEnvironment, processRunner: runner)

        #expect(environment == baseEnvironment)
        #expect(await runner.requests().count == 1)
    }

    @Test func cancelledLaunchdBuildServiceLookupPropagatesCancellation() async {
        let runner = BuildServiceEnvironmentProcessRunner(failure: .cancelled)

        await #expect(throws: CancellationError.self) {
            _ = try await NativeHostRuntime.buildServiceEnvironment(
                baseEnvironment: [:], processRunner: runner)
        }

        #expect(await runner.requests().count == 1)
    }


    @Test func nativeHostSessionUsesConfiguredHelper() throws {
        let factory = try NativeHostSessionFactory(
            configuration: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 0)), environment: [:])
        #expect(try upstreamCommand(from: factory).hasSuffix("/xcode-mcp-native-host"))
    }


    @Test func upstreamStderrLogLimiterSuppressesRepeatedMessages() {
        let limiter = UpstreamStderrLogLimiter(duplicateLogIntervalNanoseconds: 1_000_000_000)
        let message = "some upstream stderr"
        let first = limiter.decision(
            upstreamIndex: 0,
            message: message,
            nowUptimeNs: 0
        )
        let second = limiter.decision(
            upstreamIndex: 0,
            message: message,
            nowUptimeNs: 100_000_000
        )
        let third = limiter.decision(
            upstreamIndex: 0,
            message: message,
            nowUptimeNs: 1_100_000_000
        )

        #expect(first.shouldLog)
        #expect(!second.shouldLog)
        #expect(third.shouldLog)
        #expect(third.suppressedDuplicateCount == 1)
    }
}

private actor BuildServiceEnvironmentProcessRunner: ProcessRunning {
    enum Failure: Error {
        case launchFailed
        case cancelled
    }

    private let outputs: [String: ProcessOutput]
    private let failure: Failure?
    private var recordedRequests: [ProcessRequest] = []

    init(outputs: [String: ProcessOutput] = [:], failure: Failure? = nil) {
        self.outputs = outputs
        self.failure = failure
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        recordedRequests.append(request)
        #expect(request.executablePath == "/bin/launchctl")
        #expect(request.arguments.first == "getenv")
        let key = try #require(request.arguments.last)
        switch failure {
        case .launchFailed:
            throw Failure.launchFailed
        case .cancelled:
            throw CancellationError()
        case nil:
            return outputs[key] ?? ProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        }
    }

    func requests() -> [ProcessRequest] {
        recordedRequests
    }
}
