import Foundation

enum ProcessTestEnvironment {
    static let isEnabled =
        ProcessInfo.processInfo.environment["XCODE_MCP_RUN_PROCESS_TESTS"] == "1"
}
