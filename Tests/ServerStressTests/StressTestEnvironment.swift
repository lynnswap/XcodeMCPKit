import Foundation

enum StressTestEnvironment {
    static let isEnabled =
        ProcessInfo.processInfo.environment["XCODE_MCP_RUN_STRESS_TESTS"] == "1"
}
