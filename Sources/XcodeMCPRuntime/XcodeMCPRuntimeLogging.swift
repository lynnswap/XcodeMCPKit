import Logging

package enum XcodeMCPRuntimeLogging {
    private static let labelPrefix = "XcodeMCPProxy"

    package static func make(_ name: String) -> Logger {
        Logger(label: "\(labelPrefix).\(name)")
    }
}
