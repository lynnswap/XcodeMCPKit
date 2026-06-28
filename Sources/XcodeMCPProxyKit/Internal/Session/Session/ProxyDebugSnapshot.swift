import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime

enum ProxyDebug {}

extension ProxyDebug {
    struct Event: Codable, Sendable {
        let timestamp: Date
        let message: String

        init(timestamp: Date, message: String) {
            self.timestamp = timestamp
            self.message = message
        }
    }
}

extension ProxyDebug {
    struct TrafficEvent: Codable, Sendable {
        let timestamp: Date
        let upstreamIndex: Int
        let direction: String
        let bytes: Int
        let preview: String

        init(
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
    struct UpstreamSnapshot: Codable, Sendable {
        let upstreamIndex: Int
        let isInitialized: Bool
        let initInFlight: Bool
        let didSendInitialized: Bool
        let healthState: String
        let consecutiveRequestTimeouts: Int
        let consecutiveToolsListFailures: Int
        let lastToolsListSuccessUptimeNs: UInt64?
        let recentStderr: [ProxyDebug.Event]
        let lastDecodeError: ProxyDebug.Event?
        let lastBridgeError: ProxyDebug.Event?
        let protocolViolationCount: Int
        let lastProtocolViolationAt: Date?
        let lastProtocolViolationReason: String?
        let lastProtocolViolationBufferedBytes: Int?
        let lastProtocolViolationPreview: String?
        let lastProtocolViolationPreviewHex: String?
        let lastProtocolViolationLeadingByteHex: String?
        let bufferedStdoutBytes: Int
        let capacity: Int
        let requestPickCount: Int
        let activeCorrelatedRequestCount: Int
        let droppedUnmappedNotificationCount: Int
        let lateResponseDropCount: Int

        init(
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
    struct Snapshot: Codable, Sendable {
        let generatedAt: Date
        let proxyInitialized: Bool
        let cachedToolsListAvailable: Bool
        let warmupInFlight: Bool
        let controlPlane: ControlPlane.DebugSnapshot?
        let upstreams: [ProxyDebug.UpstreamSnapshot]
        let processToolCatalogs: [ProcessToolCatalogRegistry.DebugSnapshot]
        let recentTraffic: [ProxyDebug.TrafficEvent]
        let sessions: [SessionRequestPipeline.DebugSnapshot]
        let leases: [LeaseManager.DebugSnapshot]
        let queuedRequestCount: Int

        init(
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
