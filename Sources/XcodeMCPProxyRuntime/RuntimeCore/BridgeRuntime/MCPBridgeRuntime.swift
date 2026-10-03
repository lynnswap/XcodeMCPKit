import XcodeMCPCore
import Foundation

enum MCPBridgeRuntime {
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

    static func makeUpstreamPlan(
        config: Configuration,
        xcodeTargets: [XcodeProcessTarget],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPBridgeUpstreamPlan {
        var upstreams = [makeUnboundUpstreamSlot(config: config, baseEnvironment: baseEnvironment)]
        var bindings: [XcodeProcessBinding] = []
        for target in orderedXcodeTargets(xcodeTargets) {
            let slotID = UpstreamSlotID(rawValue: upstreams.count)
            upstreams.append(contentsOf: makeProcessBoundUpstreamSlots(
                config: config, xcodeTarget: target, baseEnvironment: baseEnvironment))
            bindings.append(XcodeProcessBinding(target: target, slotIDs: [slotID]))
        }
        let topology = UpstreamTopologySnapshot(slotCount: upstreams.count, xcodeProcessBindings: bindings)
        return MCPBridgeUpstreamPlan(upstreams: upstreams, xcodeProcessRoutes: topology.xcodeProcessRoutes(), topology: topology)
    }

    static func makeProcessBoundUpstreamSlots(
        config: Configuration,
        xcodeTarget: XcodeProcessTarget,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ManagedUpstreamSlot] {
        [ManagedUpstreamSlot(factory: makeProcessBoundSessionFactory(
            config: config, xcodeTarget: xcodeTarget, baseEnvironment: baseEnvironment))]
    }

    static func makeUnboundUpstreamSlot(
        config: Configuration,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ManagedUpstreamSlot {
        ManagedUpstreamSlot(factory: NativeHostSessionFactory(
            configuration: config, xcodeTarget: nil, environment: baseEnvironment))
    }

    static func makeProcessBoundSessionFactory(
        config: Configuration,
        xcodeTarget: XcodeProcessTarget,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any UpstreamSessionFactory {
        NativeHostSessionFactory(configuration: config, xcodeTarget: xcodeTarget, environment: baseEnvironment)
    }

    static func startProcessBoundSession(
        config: Configuration,
        xcodeTarget: XcodeProcessTarget,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> any UpstreamSession {
        try await makeProcessBoundSessionFactory(
            config: config, xcodeTarget: xcodeTarget, baseEnvironment: baseEnvironment).startSession()
    }

    static func makeDefaultUpstreamConfig(
        config: Configuration,
        xcodeTarget: XcodeProcessTarget?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> UpstreamProcess.Config {
        var environment = baseEnvironment
        environment.removeValue(forKey: "XCODE_PID")
        environment.removeValue(forKey: "MCP_XCODE_PID")
        environment.removeValue(forKey: "MCP_XCODE_SESSION_ID")
        let developerDirectoryURL = xcodeTarget.map { URL(fileURLWithPath: $0.developerDir) }
            ?? config.developerDirectoryURL
        let invocation = try NativeHostInvocation.resolve(
            bundleURL: config.nativeHostBundleURL,
            developerDirectoryURL: developerDirectoryURL,
            guiPID: xcodeTarget?.processID,
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

    static func orderedXcodeTargets(
        _ targets: [XcodeProcessTarget]
    ) -> [XcodeProcessTarget] {
        targets.sorted { lhs, rhs in
            let versionComparison = compareDocumentationVersion(
                lhs.xcodeVersion,
                rhs.xcodeVersion
            )
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }
            if lhs.appPath != rhs.appPath {
                return lhs.appPath < rhs.appPath
            }
            return lhs.processID < rhs.processID
        }
    }

    private static func compareDocumentationVersion(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let lhsParts = numericDocumentationVersionParts(lhs)
        let rhsParts = numericDocumentationVersionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func numericDocumentationVersionParts(_ version: String) -> [Int] {
        version
            .split { character in
                !character.isNumber
            }
            .compactMap { Int($0) }
    }
}

struct MCPBridgeUpstreamPlan: Sendable {
    let upstreams: [ManagedUpstreamSlot]
    let xcodeProcessRoutes: [XcodeProcessRoute]
    let topology: UpstreamTopologySnapshot

    init(
        upstreams: [ManagedUpstreamSlot],
        xcodeProcessRoutes: [XcodeProcessRoute] = [],
        topology: UpstreamTopologySnapshot? = nil
    ) {
        self.upstreams = upstreams
        self.topology = topology ?? UpstreamTopologySnapshot(
            slotCount: upstreams.count,
            xcodeProcessBindings: xcodeProcessRoutes.map { route in
                XcodeProcessBinding(
                    target: route.target,
                    slotIDs: route.upstreamIndices.map { UpstreamSlotID(rawValue: $0) }
                )
            }
        )
        self.xcodeProcessRoutes = xcodeProcessRoutes.isEmpty
            ? self.topology.xcodeProcessRoutes()
            : xcodeProcessRoutes
    }
}

struct NativeHostSessionFactory: UpstreamSessionFactory {
    let configuration: MCPBridgeRuntime.Configuration
    let xcodeTarget: XcodeProcessTarget?
    let environment: [String: String]

    func processConfiguration() throws -> UpstreamProcess.Config {
        try MCPBridgeRuntime.makeDefaultUpstreamConfig(
            config: configuration, xcodeTarget: xcodeTarget, baseEnvironment: environment)
    }

    func startSession() async throws -> any UpstreamSession {
        try await UpstreamProcess(configuration: processConfiguration()).startSession()
    }
}
