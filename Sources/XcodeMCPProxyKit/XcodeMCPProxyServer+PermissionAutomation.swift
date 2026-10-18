import Logging
import XcodeMCPPermissionAutomation

protocol ProxyServerPermissionDialogAutoApprover: Sendable {
    func start()
    func cancel()
    func shutdown() async
}

extension XcodePermissionDialogAutomation.AutoApprover: ProxyServerPermissionDialogAutoApprover {
    static func liveForAllAgents(assistantName: String?) -> Self {
        let names = Set(["XcodeMCPKit", "XcodeMCPProxyKit"] + [assistantName].compactMap { $0 })
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
            logger: XcodeMCPProxyLogging.make("xcode.permission")
        )
    }
}
