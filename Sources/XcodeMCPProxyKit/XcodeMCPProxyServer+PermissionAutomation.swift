import Logging
import XcodeMCPPermissionAutomation
import XcodeMCPProxyRuntime

protocol ProxyServerPermissionDialogAutoApprover: Sendable {
    func start()
    func cancel()
    func shutdown() async
}

extension XcodePermissionDialogAutomation.AutoApprover: ProxyServerPermissionDialogAutoApprover {
    static func liveForAllAgents() -> Self {
        let names: Set<String> = ["XcodeMCPKit", "XcodeMCPProxyKit"]
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
            logger: ProxyLogging.make("xcode.permission")
        )
    }
}
