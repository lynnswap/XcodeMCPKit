import Foundation
import ProxyCore
import ProxySessionUpstream

package enum MCPBridgeRuntime {
    package static func makeUpstreamPlan(
        config: ProxyConfig,
        sharedSessionID: String?,
        count: Int,
        xcodeTargets: [XcodeProcessTarget]
    ) -> MCPBridgeUpstreamPlan {
        let orderedXcodeTargets = orderedXcodeTargets(xcodeTargets)
        let canUseProcessBoundXcodeUpstreams =
            orderedXcodeTargets.isEmpty == false
            && supportsProcessBoundRouting(config: config)
        var upstreams: [ManagedUpstreamSlot] = []
        var xcodeProcessBindings: [XcodeProcessBinding] = []
        let upstreamCount = max(1, count)

        if canUseProcessBoundXcodeUpstreams {
            upstreams.reserveCapacity(orderedXcodeTargets.count * upstreamCount)
            xcodeProcessBindings.reserveCapacity(orderedXcodeTargets.count)

            for target in orderedXcodeTargets {
                var slotIDs: [UpstreamSlotID] = []
                slotIDs.reserveCapacity(upstreamCount)
                for _ in 0..<upstreamCount {
                    let upstreamIndex = upstreams.count
                    let upstreamConfig = makeDefaultUpstreamConfig(
                        config: config,
                        sharedSessionID: sharedSessionID,
                        xcodeTarget: target
                    )
                    upstreams.append(
                        ManagedUpstreamSlot(factory: UpstreamProcess(config: upstreamConfig))
                    )
                    slotIDs.append(UpstreamSlotID(rawValue: upstreamIndex))
                }

                xcodeProcessBindings.append(
                    XcodeProcessBinding(target: target, slotIDs: slotIDs)
                )
            }
        } else {
            upstreams.reserveCapacity(upstreamCount)
            for _ in 0..<upstreamCount {
                let upstreamConfig = makeDefaultUpstreamConfig(
                    config: config,
                    sharedSessionID: sharedSessionID,
                    xcodeTarget: nil
                )
                upstreams.append(
                    ManagedUpstreamSlot(factory: UpstreamProcess(config: upstreamConfig))
                )
            }
        }

        let topology = UpstreamTopologySnapshot(
            slotCount: upstreams.count,
            xcodeProcessBindings: xcodeProcessBindings
        )
        return MCPBridgeUpstreamPlan(
            upstreams: upstreams,
            xcodeProcessRoutes: topology.xcodeProcessRoutes(),
            topology: topology
        )
    }

    package static func supportsProcessBoundRouting(config: ProxyConfig) -> Bool {
        XcrunArguments.isDefaultMCPBridgeInvocation(config: config)
    }

    package static func makeProcessBoundSessionFactory(
        config: ProxyConfig,
        sharedSessionID: String?,
        xcodeTarget: XcodeProcessTarget,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any UpstreamSessionFactory {
        UpstreamProcess(config: makeDefaultUpstreamConfig(
            config: config,
            sharedSessionID: sharedSessionID,
            xcodeTarget: xcodeTarget,
            baseEnvironment: baseEnvironment
        ))
    }

    package static func startProcessBoundSession(
        config: ProxyConfig,
        sharedSessionID: String?,
        xcodeTarget: XcodeProcessTarget,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> any UpstreamSession {
        try await makeProcessBoundSessionFactory(
            config: config,
            sharedSessionID: sharedSessionID,
            xcodeTarget: xcodeTarget,
            baseEnvironment: baseEnvironment
        ).startSession()
    }

    private static func makeDefaultUpstreamConfig(
        config: ProxyConfig,
        sharedSessionID: String?,
        xcodeTarget: XcodeProcessTarget?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UpstreamProcess.Config {
        var environment = baseEnvironment
        environment.removeValue(forKey: "XCODE_PID")
        if let sharedSessionID, !sharedSessionID.isEmpty {
            environment["MCP_XCODE_SESSION_ID"] = sharedSessionID
        } else {
            environment.removeValue(forKey: "MCP_XCODE_SESSION_ID")
        }
        let command: String
        let args: [String]
        if let xcodeTarget {
            environment["MCP_XCODE_PID"] = String(xcodeTarget.processID)
            environment["DEVELOPER_DIR"] = xcodeTarget.developerDir
            command = xcodeTarget.mcpbridgePath
            args = []
        } else {
            command = config.upstreamCommand
            args = config.upstreamArgs
        }
        return UpstreamProcess.Config(
            command: command,
            args: args,
            environment: environment,
            maxQueuedWriteBytes: maxQueuedWriteBytes(for: config)
        )
    }

    private static func maxQueuedWriteBytes(for config: ProxyConfig) -> Int {
        let minimum = 1_048_576
        guard config.maxBodyBytes > 0 else { return minimum }
        let multiplied = config.maxBodyBytes.multipliedReportingOverflow(by: 4)
        if multiplied.overflow {
            return Int.max
        }
        return max(minimum, multiplied.partialValue)
    }

    private static func orderedXcodeTargets(
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

package struct MCPBridgeUpstreamPlan: Sendable {
    package let upstreams: [ManagedUpstreamSlot]
    package let xcodeProcessRoutes: [XcodeProcessRoute]
    package let topology: UpstreamTopologySnapshot

    package init(
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
