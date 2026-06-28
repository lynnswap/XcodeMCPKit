import XcodeMCPKit
import Foundation

enum SessionRequestPipeline {
    struct Descriptor: Codable, Sendable {
        let sessionID: String
        let label: String
        let isBatch: Bool
        let expectsResponse: Bool
        let isTopLevelClientRequest: Bool

        init(
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

    struct DebugSnapshot: Codable, Sendable {
        let sessionID: String
        let activeCorrelatedRequestCount: Int

        init(
            sessionID: String,
            activeCorrelatedRequestCount: Int
        ) {
            self.sessionID = sessionID
            self.activeCorrelatedRequestCount = activeCorrelatedRequestCount
        }

        var hasActiveRequest: Bool { activeCorrelatedRequestCount > 0 }
        var currentRequestLabel: String? { nil }
        var currentRequestStartedAt: Date? { nil }
        var pendingRequestCount: Int { 0 }
    }
}
