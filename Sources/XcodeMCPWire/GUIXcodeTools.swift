/// Tools whose context and results belong to the running GUI Xcode, rather than an owned workspace.
package enum GUIXcodeTools {
    package static let names: Set<String> = ["XcodeListWindows", "GetTopCrashIssues", "GetCrashIssueLogs"]
}
