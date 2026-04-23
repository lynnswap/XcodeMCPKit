import Foundation

package struct ProxyDebugEvent: Codable, Sendable {
    package let timestamp: Date
    package let message: String

    package init(timestamp: Date, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

package struct ProxyDebugTrafficEvent: Codable, Sendable {
    package let timestamp: Date
    package let upstreamIndex: Int
    package let direction: String
    package let bytes: Int
    package let preview: String

    package init(timestamp: Date, upstreamIndex: Int, direction: String, bytes: Int, preview: String) {
        self.timestamp = timestamp
        self.upstreamIndex = upstreamIndex
        self.direction = direction
        self.bytes = bytes
        self.preview = preview
    }
}

package struct ProxyUpstreamDebugSnapshot: Codable, Sendable {
    package let upstreamIndex: Int
    package let isInitialized: Bool
    package let initInFlight: Bool
    package let didSendInitialized: Bool
    package let healthState: String
    package let consecutiveRequestTimeouts: Int
    package let consecutiveToolsListFailures: Int
    package let lastToolsListSuccessUptimeNs: UInt64?
    package let recentStderr: [ProxyDebugEvent]
    package let lastDecodeError: ProxyDebugEvent?
    package let lastBridgeError: ProxyDebugEvent?
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
        recentStderr: [ProxyDebugEvent],
        lastDecodeError: ProxyDebugEvent?,
        lastBridgeError: ProxyDebugEvent?,
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

package struct ProxyDebugSnapshot: Codable, Sendable {
    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let cachedToolsListAvailable: Bool
    package let warmupInFlight: Bool
    package let upstreams: [ProxyUpstreamDebugSnapshot]
    package let recentTraffic: [ProxyDebugTrafficEvent]
    package let sessions: [SessionDebugSnapshot]
    package let leases: [RequestLeaseDebugSnapshot]
    package let queuedRequestCount: Int

    package init(
        generatedAt: Date,
        proxyInitialized: Bool,
        cachedToolsListAvailable: Bool,
        warmupInFlight: Bool,
        upstreams: [ProxyUpstreamDebugSnapshot],
        recentTraffic: [ProxyDebugTrafficEvent],
        sessions: [SessionDebugSnapshot],
        leases: [RequestLeaseDebugSnapshot],
        queuedRequestCount: Int
    ) {
        self.generatedAt = generatedAt
        self.proxyInitialized = proxyInitialized
        self.cachedToolsListAvailable = cachedToolsListAvailable
        self.warmupInFlight = warmupInFlight
        self.upstreams = upstreams
        self.recentTraffic = recentTraffic
        self.sessions = sessions
        self.leases = leases
        self.queuedRequestCount = queuedRequestCount
    }
}
