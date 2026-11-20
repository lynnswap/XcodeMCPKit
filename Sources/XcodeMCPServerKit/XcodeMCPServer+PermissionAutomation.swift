import Logging
import XcodeMCPPermissionAutomation
import XcodeMCPServerRuntime

protocol ServerPermissionDialogAutoApprover: Sendable {
    func start()
    func cancel()
    func shutdown() async
}

extension XcodePermissionDialogAutomation.AutoApprover: ServerPermissionDialogAutoApprover {
    static func liveForAllAgents() -> Self {
        let names: Set<String> = ["XcodeMCPKit", "XcodeMCPServerKit"]
        return Self(
            configuration: .init(
                permissionDialogProcessIDs: {
                    XcodePermissionDialogAutomation.runningPermissionDialogProcessIDs()
                },
                agentPathCandidates: { executablePathCandidates() },
                assistantNameCandidates: { names },
                agentProcessIDCandidates: { descendantProcessIDCandidates() },
                agentScope: .allAgents
            ),
            logger: ServerLogging.make("xcode.permission")
        )
    }
}
