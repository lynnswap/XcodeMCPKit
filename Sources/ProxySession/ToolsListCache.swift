import Foundation
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

package final class ToolsListCache: Sendable {
    private struct State: Sendable {
        var cachedResult: JSONValue?
        var warmupInFlight = false
        var internalSessionID: String?
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func cachedResult() -> JSONValue? {
        state.withLockedValue { $0.cachedResult }
    }

    package func setCachedResult(_ result: JSONValue) {
        state.withLockedValue { $0.cachedResult = result }
    }

    package func beginWarmupIfNeeded(isEnabled: Bool, isInitialized: Bool) -> Bool {
        guard isEnabled, isInitialized else { return false }
        return state.withLockedValue { state in
            if state.cachedResult != nil || state.warmupInFlight {
                return false
            }
            state.warmupInFlight = true
            return true
        }
    }

    package func endWarmup() {
        state.withLockedValue { $0.warmupInFlight = false }
    }

    package func snapshot() -> (cachedResult: JSONValue?, warmupInFlight: Bool) {
        state.withLockedValue { ($0.cachedResult, $0.warmupInFlight) }
    }

    package func reset() {
        state.withLockedValue { state in
            state.cachedResult = nil
            state.warmupInFlight = false
        }
    }

    package func internalSessionID(hasSession: (String) -> Bool) -> String {
        if let existing = state.withLockedValue({ $0.internalSessionID }) {
            return existing
        }

        var candidate: String
        repeat {
            candidate = "__tools_list_warmup__:" + UUID().uuidString
        } while hasSession(candidate)

        return state.withLockedValue { state in
            if let existing = state.internalSessionID {
                return existing
            }
            state.internalSessionID = candidate
            return candidate
        }
    }
}
