import Foundation
import ProxyCore

package struct SessionPipelineRequestDescriptor: Codable, Sendable {
    package let sessionID: String
    package let label: String
    package let isBatch: Bool
    package let expectsResponse: Bool
    package let isTopLevelClientRequest: Bool

    package init(
        sessionID: String,
        label: String,
        isBatch: Bool,
        expectsResponse: Bool,
        isTopLevelClientRequest: Bool
    ) {
        self.sessionID = sessionID
        self.label = label
        self.isBatch = isBatch
        self.expectsResponse = expectsResponse
        self.isTopLevelClientRequest = isTopLevelClientRequest
    }
}

package struct SessionDebugSnapshot: Codable, Sendable {
    package let sessionID: String
    package let activeCorrelatedRequestCount: Int

    package init(
        sessionID: String,
        activeCorrelatedRequestCount: Int
    ) {
        self.sessionID = sessionID
        self.activeCorrelatedRequestCount = activeCorrelatedRequestCount
    }

    package var hasActiveRequest: Bool { activeCorrelatedRequestCount > 0 }
    package var currentRequestLabel: String? { nil }
    package var currentRequestStartedAt: Date? { nil }
    package var pendingRequestCount: Int { 0 }
}

package enum UpstreamSlotAcquisitionError: Error {
    case unavailable
}
