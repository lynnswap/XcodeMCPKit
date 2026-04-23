import Foundation
import NIO

package enum MCPMethodDispatcher {
    private static let capped20sMethods: Set<String> = [
        "resources/list",
        "resources/templates/list",
    ]
    private static let initializeFallbackTimeoutSeconds: TimeInterval = 60

    package static func timeoutForInitialize(defaultSeconds: TimeInterval) -> TimeAmount? {
        let effectiveDefault = defaultSeconds > 0 ? defaultSeconds : initializeFallbackTimeoutSeconds
        return timeout(defaultSeconds: effectiveDefault, capSeconds: initializeFallbackTimeoutSeconds)
    }

    package static func timeoutForMethod(
        _ method: String?,
        defaultSeconds: TimeInterval
    ) -> TimeAmount? {
        guard let method else {
            return makeRequestTimeout(defaultSeconds)
        }
        if method == "initialize" {
            return timeout(defaultSeconds: defaultSeconds, capSeconds: 60)
        }
        if capped20sMethods.contains(method) {
            return timeout(defaultSeconds: defaultSeconds, capSeconds: 20)
        }
        return makeRequestTimeout(defaultSeconds)
    }

    package static func timeoutForControlPlane(
        defaultSeconds: TimeInterval
    ) -> TimeAmount? {
        if defaultSeconds > 0 {
            return makeRequestTimeout(defaultSeconds)
        }
        return .seconds(60)
    }

    private static func timeout(
        defaultSeconds: TimeInterval,
        capSeconds: TimeInterval
    ) -> TimeAmount? {
        guard defaultSeconds > 0 else { return nil }
        return makeRequestTimeout(min(defaultSeconds, capSeconds))
    }

    private static func makeRequestTimeout(_ seconds: TimeInterval) -> TimeAmount? {
        guard seconds > 0 else { return nil }
        let whole = Int64(seconds)
        let fractional = seconds - Double(whole)
        let nanos = Int64((fractional * 1_000_000_000).rounded())
        return .seconds(whole) + .nanoseconds(nanos)
    }
}
