import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class ProxyDebugRecorder: Sendable {
    private struct DebugUpstreamState: Sendable {
        var recentStderr: [ProxyDebug.Event] = []
        var lastDecodeError: ProxyDebug.Event?
        var lastBridgeError: ProxyDebug.Event?
        var protocolViolationCount = 0
        var lastProtocolViolationAt: Date?
        var lastProtocolViolationReason: String?
        var lastProtocolViolationBufferedBytes: Int?
        var lastProtocolViolationPreview: String?
        var lastProtocolViolationPreviewHex: String?
        var lastProtocolViolationLeadingByteHex: String?
        var bufferedStdoutBytes = 0
        var droppedUnmappedNotificationCount = 0
        var lateResponseDropCount = 0
    }

    private struct State: Sendable {
        var upstreams: [DebugUpstreamState] = []
        var recentTraffic: [ProxyDebug.TrafficEvent] = []
    }

    private let state = NIOLockedValueBox(State())
    private let trafficLimit: Int
    private let stderrLimit: Int

    init(
        upstreamCount: Int,
        trafficLimit: Int = 50,
        stderrLimit: Int = 20
    ) {
        self.trafficLimit = trafficLimit
        self.stderrLimit = stderrLimit
        state.withLockedValue { state in
            state.upstreams = Array(repeating: DebugUpstreamState(), count: upstreamCount)
            state.recentTraffic = []
        }
    }

    func appendUpstreams(count: Int) {
        guard count > 0 else { return }
        state.withLockedValue { state in
            state.upstreams.append(contentsOf: Array(repeating: DebugUpstreamState(), count: count))
        }
    }

    func resetUpstream(_ upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex] = DebugUpstreamState()
        }
    }

    func resetAll() {
        state.withLockedValue { state in
            state.upstreams = Array(repeating: DebugUpstreamState(), count: state.upstreams.count)
            state.recentTraffic.removeAll()
        }
    }

    func recordStderr(_ message: String, upstreamIndex: Int) {
        let event = ProxyDebug.Event(timestamp: Date(), message: message)
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].recentStderr.append(event)
            if state.upstreams[upstreamIndex].recentStderr.count > stderrLimit {
                state.upstreams[upstreamIndex].recentStderr.removeFirst(
                    state.upstreams[upstreamIndex].recentStderr.count - stderrLimit
                )
            }
            if message.contains("Could not decode agent message") {
                state.upstreams[upstreamIndex].lastDecodeError = event
            }
            if message.contains("BridgeError") {
                state.upstreams[upstreamIndex].lastBridgeError = event
            }
        }
    }

    func recordProtocolViolation(
        _ protocolViolation: StdioFramer.ProtocolViolation,
        upstreamIndex: Int
    ) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].protocolViolationCount += 1
            state.upstreams[upstreamIndex].lastProtocolViolationAt = Date()
            state.upstreams[upstreamIndex].lastProtocolViolationReason =
                protocolViolation.reason.rawValue
            state.upstreams[upstreamIndex].lastProtocolViolationBufferedBytes =
                protocolViolation.bufferedByteCount
            state.upstreams[upstreamIndex].lastProtocolViolationPreview =
                protocolViolation.preview
            state.upstreams[upstreamIndex].lastProtocolViolationPreviewHex =
                protocolViolation.previewHex
            state.upstreams[upstreamIndex].lastProtocolViolationLeadingByteHex =
                protocolViolation.leadingByteHex
        }
    }

    func recordBufferedStdoutBytes(_ size: Int, upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].bufferedStdoutBytes = size
        }
    }

    func recordDroppedUnmappedNotification(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].droppedUnmappedNotificationCount += 1
        }
    }

    func recordLateResponse(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreams.count else { return }
            state.upstreams[upstreamIndex].lateResponseDropCount += 1
        }
    }

    func recordTraffic(
        upstreamIndex: Int, direction: String, data: Data, redactedText: String
    ) {
        let event = ProxyDebug.TrafficEvent(
            timestamp: Date(),
            upstreamIndex: upstreamIndex,
            direction: direction,
            bytes: data.count,
            preview: redactedText
        )
        state.withLockedValue { state in
            state.recentTraffic.append(event)
            if state.recentTraffic.count > trafficLimit {
                state.recentTraffic.removeFirst(state.recentTraffic.count - trafficLimit)
            }
        }
    }

    func snapshot(
        proxyInitialized: Bool,
        cachedToolsListAvailable: Bool,
        controlPlane: ControlPlane.DebugSnapshot?,
        processRoutes: [ProxyDebug.ProcessRouteSnapshot],
        processToolCatalogs: [ProcessToolSurfaceStore.DebugSnapshot],
        upstreamStates: [UpstreamHealthManager.UpstreamState],
        sessionSnapshots: [SessionRequestPipeline.DebugSnapshot],
        leaseSnapshots: [LeaseManager.DebugSnapshot],
        queuedRequestCount: Int,
        redactedText: String,
        includeSensitiveDebugPayloads: Bool,
        healthFormatter: (Upstream.HealthState) -> String
    ) -> ProxyDebug.Snapshot {
        let recordedState = state.withLockedValue { state in
            (upstreams: state.upstreams, recentTraffic: state.recentTraffic)
        }
        let activeCountsByUpstream = leaseSnapshots.reduce(into: [Int: Int]()) { counts, lease in
            guard lease.state == .active, let upstreamIndex = lease.upstreamIndex else { return }
            counts[upstreamIndex, default: 0] += 1
        }

        let upstreamSnapshots = upstreamStates.enumerated().map { index, upstream in
            let debug =
                index < recordedState.upstreams.count
                ? recordedState.upstreams[index] : DebugUpstreamState()
            return ProxyDebug.UpstreamSnapshot(
                upstreamIndex: index,
                isInitialized: upstream.isInitialized,
                initInFlight: upstream.initInFlight,
                didSendInitialized: upstream.didSendInitialized,
                healthState: healthFormatter(upstream.healthState),
                consecutiveRequestTimeouts: upstream.consecutiveRequestTimeouts,
                consecutiveToolsListFailures: upstream.consecutiveToolsListFailures,
                lastToolsListSuccessUptimeNs: upstream.lastToolsListSuccessUptimeNs,
                recentStderr: debug.recentStderr.map { event in
                    ProxyDebug.Event(timestamp: event.timestamp, message: redactedText)
                },
                lastDecodeError: debug.lastDecodeError.map {
                    ProxyDebug.Event(timestamp: $0.timestamp, message: redactedText)
                },
                lastBridgeError: debug.lastBridgeError.map {
                    ProxyDebug.Event(timestamp: $0.timestamp, message: redactedText)
                },
                protocolViolationCount: debug.protocolViolationCount,
                lastProtocolViolationAt: debug.lastProtocolViolationAt,
                lastProtocolViolationReason: debug.lastProtocolViolationReason,
                lastProtocolViolationBufferedBytes: debug.lastProtocolViolationBufferedBytes,
                lastProtocolViolationPreview: debug.lastProtocolViolationPreview.map { preview in
                    includeSensitiveDebugPayloads ? preview : redactedText
                },
                lastProtocolViolationPreviewHex: debug.lastProtocolViolationPreviewHex.map { hex in
                    includeSensitiveDebugPayloads ? hex : redactedText
                },
                lastProtocolViolationLeadingByteHex: includeSensitiveDebugPayloads
                    ? debug.lastProtocolViolationLeadingByteHex
                    : debug.lastProtocolViolationLeadingByteHex.map { _ in redactedText },
                bufferedStdoutBytes: debug.bufferedStdoutBytes,
                capacity: 1,
                requestPickCount: upstream.requestPickCount,
                activeCorrelatedRequestCount: activeCountsByUpstream[index] ?? 0,
                droppedUnmappedNotificationCount: debug.droppedUnmappedNotificationCount,
                lateResponseDropCount: debug.lateResponseDropCount
            )
        }

        return ProxyDebug.Snapshot(
            generatedAt: Date(),
            proxyInitialized: proxyInitialized,
            cachedToolsListAvailable: cachedToolsListAvailable,
            warmupInFlight: controlPlane?.phase == "loading_tools_catalog",
            controlPlane: controlPlane,
            upstreams: upstreamSnapshots,
            processRoutes: processRoutes,
            processToolCatalogs: processToolCatalogs,
            recentTraffic: recordedState.recentTraffic.map {
                ProxyDebug.TrafficEvent(
                    timestamp: $0.timestamp,
                    upstreamIndex: $0.upstreamIndex,
                    direction: $0.direction,
                    bytes: $0.bytes,
                    preview: redactedText
                )
            },
            sessions: sessionSnapshots,
            leases: leaseSnapshots,
            queuedRequestCount: queuedRequestCount
        )
    }
}
