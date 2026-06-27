import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

package enum ProxyDebug {}

extension ProxyDebug {
    package struct Event: Codable, Sendable {
        package let timestamp: Date
        package let message: String

        package init(timestamp: Date, message: String) {
            self.timestamp = timestamp
            self.message = message
        }
    }
}

extension ProxyDebug {
    package struct TrafficEvent: Codable, Sendable {
        package let timestamp: Date
        package let upstreamIndex: Int
        package let direction: String
        package let bytes: Int
        package let preview: String

        package init(
            timestamp: Date, upstreamIndex: Int, direction: String, bytes: Int, preview: String
        ) {
            self.timestamp = timestamp
            self.upstreamIndex = upstreamIndex
            self.direction = direction
            self.bytes = bytes
            self.preview = preview
        }
    }
}

extension ProxyDebug {
    package struct UpstreamSnapshot: Codable, Sendable {
        package let upstreamIndex: Int
        package let isInitialized: Bool
        package let initInFlight: Bool
        package let didSendInitialized: Bool
        package let healthState: String
        package let consecutiveRequestTimeouts: Int
        package let consecutiveToolsListFailures: Int
        package let lastToolsListSuccessUptimeNs: UInt64?
        package let recentStderr: [ProxyDebug.Event]
        package let lastDecodeError: ProxyDebug.Event?
        package let lastBridgeError: ProxyDebug.Event?
        package let protocolViolationCount: Int
        package let lastProtocolViolationAt: Date?
        package let lastProtocolViolationReason: String?
        package let lastProtocolViolationBufferedBytes: Int?
        package let lastProtocolViolationPreview: String?
        package let lastProtocolViolationPreviewHex: String?
        package let lastProtocolViolationLeadingByteHex: String?
        package let bufferedStdoutBytes: Int
        package let capacity: Int
        package let requestPickCount: Int
        package let activeCorrelatedRequestCount: Int
        package let droppedUnmappedNotificationCount: Int
        package let lateResponseDropCount: Int

        package init(
            upstreamIndex: Int,
            isInitialized: Bool,
            initInFlight: Bool,
            didSendInitialized: Bool,
            healthState: String,
            consecutiveRequestTimeouts: Int,
            consecutiveToolsListFailures: Int,
            lastToolsListSuccessUptimeNs: UInt64?,
            recentStderr: [ProxyDebug.Event],
            lastDecodeError: ProxyDebug.Event?,
            lastBridgeError: ProxyDebug.Event?,
            protocolViolationCount: Int,
            lastProtocolViolationAt: Date?,
            lastProtocolViolationReason: String?,
            lastProtocolViolationBufferedBytes: Int?,
            lastProtocolViolationPreview: String?,
            lastProtocolViolationPreviewHex: String?,
            lastProtocolViolationLeadingByteHex: String?,
            bufferedStdoutBytes: Int,
            capacity: Int = 1,
            requestPickCount: Int = 0,
            activeCorrelatedRequestCount: Int = 0,
            droppedUnmappedNotificationCount: Int = 0,
            lateResponseDropCount: Int = 0
        ) {
            self.upstreamIndex = upstreamIndex
            self.isInitialized = isInitialized
            self.initInFlight = initInFlight
            self.didSendInitialized = didSendInitialized
            self.healthState = healthState
            self.consecutiveRequestTimeouts = consecutiveRequestTimeouts
            self.consecutiveToolsListFailures = consecutiveToolsListFailures
            self.lastToolsListSuccessUptimeNs = lastToolsListSuccessUptimeNs
            self.recentStderr = recentStderr
            self.lastDecodeError = lastDecodeError
            self.lastBridgeError = lastBridgeError
            self.protocolViolationCount = protocolViolationCount
            self.lastProtocolViolationAt = lastProtocolViolationAt
            self.lastProtocolViolationReason = lastProtocolViolationReason
            self.lastProtocolViolationBufferedBytes = lastProtocolViolationBufferedBytes
            self.lastProtocolViolationPreview = lastProtocolViolationPreview
            self.lastProtocolViolationPreviewHex = lastProtocolViolationPreviewHex
            self.lastProtocolViolationLeadingByteHex = lastProtocolViolationLeadingByteHex
            self.bufferedStdoutBytes = bufferedStdoutBytes
            self.capacity = capacity
            self.requestPickCount = requestPickCount
            self.activeCorrelatedRequestCount = activeCorrelatedRequestCount
            self.droppedUnmappedNotificationCount = droppedUnmappedNotificationCount
            self.lateResponseDropCount = lateResponseDropCount
        }
    }
}

extension ProxyDebug {
    package struct Snapshot: Codable, Sendable {
        package let generatedAt: Date
        package let proxyInitialized: Bool
        package let cachedToolsListAvailable: Bool
        package let warmupInFlight: Bool
        package let controlPlane: ControlPlane.DebugSnapshot?
        package let upstreams: [ProxyDebug.UpstreamSnapshot]
        package let processToolCatalogs: [ProcessToolCatalogRegistry.DebugSnapshot]
        package let recentTraffic: [ProxyDebug.TrafficEvent]
        package let sessions: [SessionRequestPipeline.DebugSnapshot]
        package let leases: [LeaseManager.DebugSnapshot]
        package let queuedRequestCount: Int

        package init(
            generatedAt: Date,
            proxyInitialized: Bool,
            cachedToolsListAvailable: Bool,
            warmupInFlight: Bool,
            controlPlane: ControlPlane.DebugSnapshot? = nil,
            upstreams: [ProxyDebug.UpstreamSnapshot],
            processToolCatalogs: [ProcessToolCatalogRegistry.DebugSnapshot] = [],
            recentTraffic: [ProxyDebug.TrafficEvent],
            sessions: [SessionRequestPipeline.DebugSnapshot],
            leases: [LeaseManager.DebugSnapshot],
            queuedRequestCount: Int
        ) {
            self.generatedAt = generatedAt
            self.proxyInitialized = proxyInitialized
            self.cachedToolsListAvailable = cachedToolsListAvailable
            self.warmupInFlight = warmupInFlight
            self.controlPlane = controlPlane
            self.upstreams = upstreams
            self.processToolCatalogs = processToolCatalogs
            self.recentTraffic = recentTraffic
            self.sessions = sessions
            self.leases = leases
            self.queuedRequestCount = queuedRequestCount
        }
    }
}
