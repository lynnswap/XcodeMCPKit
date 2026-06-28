import Foundation
import NIO

extension MCP {
    package enum MethodDispatcher {
        private static let capped20sMethods: Set<String> = [
            "resources/list",
            "resources/templates/list",
        ]
        private static let initializeFallbackTimeoutSeconds: TimeInterval = 60
        private static let controlPlaneFallbackTimeoutSeconds: TimeInterval = 10

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
