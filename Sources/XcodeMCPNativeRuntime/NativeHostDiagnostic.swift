import Foundation

package enum NativeHostDiagnostic {
    package enum Level: String {
        case warning = "WARNING"
        case error = "ERROR"
    }

    package static func report(_ message: String, level: Level = .error) {
        try? FileHandle.standardError.write(contentsOf: Data((formattedMessage(message, level: level) + "\n").utf8))
    }

    static func formattedMessage(_ message: String, level: Level) -> String {
        // The proxy classifies stderr one line at a time, including multiline errors.
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "[xcode-mcp-native-host] \(level.rawValue) : \($0)" }
            .joined(separator: "\n")
    }
}
