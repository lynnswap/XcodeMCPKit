import ArgumentParser
import Foundation
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

    @Test func explicitProcessInventoryRejectsExitedAndReusedProcessIDs() throws {
        let originalIdentity = ExplicitProcessIdentity(
            processID: 42,
            startTimeSeconds: 100,
            startTimeMicroseconds: 200
        )
        let identities = MutableProcessIdentities([42: originalIdentity])
        let inventory = ExplicitProcessInventory(
            identities: [originalIdentity],
            currentIdentity: { processID in
                identities.identity(for: processID)
            }
        )

        #expect(inventory.runningProcessIDs() == [42])

        identities.replace(with: [:])
        #expect(inventory.runningProcessIDs().isEmpty)

        identities.replace(with: [
            42: ExplicitProcessIdentity(
                processID: 42,
                startTimeSeconds: 101,
                startTimeMicroseconds: 0
            )
        ])
        #expect(inventory.runningProcessIDs().isEmpty)
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

private final class MutableProcessIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [pid_t: ExplicitProcessIdentity]

    init(_ identities: [pid_t: ExplicitProcessIdentity]) {
        self.identities = identities
    }

    func identity(for processID: pid_t) -> ExplicitProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identities[processID]
    }

    func replace(with identities: [pid_t: ExplicitProcessIdentity]) {
        lock.lock()
        self.identities = identities
        lock.unlock()
    }
}
