import Foundation
import NIOCore

extension MCP {
    package enum MethodDispatcher {
        private static let initializeFallbackTimeoutSeconds: TimeInterval = 60
        private static let controlPlaneFallbackTimeoutSeconds: TimeInterval = 10

        package static func timeoutForInitialize(defaultSeconds: TimeInterval) -> TimeAmount? {
            let effectiveDefault = defaultSeconds > 0 ? defaultSeconds : initializeFallbackTimeoutSeconds
            return timeout(defaultSeconds: effectiveDefault, capSeconds: initializeFallbackTimeoutSeconds)
        }

        package static func timeoutForControlPlane(
            defaultSeconds: TimeInterval
        ) -> TimeAmount? {
            let effectiveDefault = defaultSeconds > 0
                ? defaultSeconds
                : controlPlaneFallbackTimeoutSeconds
            return timeout(
                defaultSeconds: effectiveDefault,
                capSeconds: controlPlaneFallbackTimeoutSeconds
            )
        }

        private static func timeout(
            defaultSeconds: TimeInterval,
            capSeconds: TimeInterval
        ) -> TimeAmount? {
            guard defaultSeconds > 0 else { return nil }
            return makeRequestTimeout(min(defaultSeconds, capSeconds))
        }
    }
}
