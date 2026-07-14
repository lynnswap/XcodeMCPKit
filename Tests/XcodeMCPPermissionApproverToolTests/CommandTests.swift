import ArgumentParser
import Testing
@testable import XcodeMCPPermissionApproverTool

@Suite
struct PermissionApproverCommandTests {
    @Test func requiresExplicitXcodeAndAgentProcessIdentities() {
        #expect(
            parseFailure([]).contains("at least one --xcode-pid is required")
        )
        #expect(
            parseFailure([
                "--xcode-pid", "42",
                "--assistant-name", "XcodeMCPKit",
            ]).contains("at least one --agent-pid is required")
        )
    }

    @Test func requiresAnExactAgentPathOrAssistantName() {
        #expect(
            parseFailure([
                "--xcode-pid", "42",
                "--agent-pid", "84",
            ]).contains("at least one non-empty --agent-path or --assistant-name is required")
        )
    }

    @Test func rejectsDeadAgentProcesses() {
        #expect(throws: (any Error).self) {
            try XcodeMCPPermissionApproverCommand.validateAgentProcesses([84]) { _ in false }
        }
    }

    @Test func rejectsNonXcodeProcessTargets() {
        #expect(throws: (any Error).self) {
            try XcodeMCPPermissionApproverCommand.validateXcodeProcesses([42]) { _ in
                "com.example.NotXcode"
            }
        }
    }

    @Test func acceptsKnownXcodeAndPermissionHelperTargets() throws {
        try XcodeMCPPermissionApproverCommand.validateXcodeProcesses([42, 43]) { processID in
            processID == 42
                ? "com.apple.dt.Xcode"
                : "com.apple.dt.ExternalViewService"
        }
    }

    private func parseFailure(_ arguments: [String]) -> String {
        do {
            _ = try XcodeMCPPermissionApproverCommand.parse(arguments)
            Issue.record("expected command parsing to fail")
            return ""
        } catch {
            return String(describing: error)
        }
    }
}
