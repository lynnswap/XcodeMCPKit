@testable import XcodeMCPCore
import XcodeMCPKit
import XcodeMCPCoreTestSupport

/// Registers terminal client cleanup with the active test scope.
func closeAfterTest(_ client: XcodeMCP) {
    precondition(
        registerAsyncTestCleanup(
            description: "XcodeMCP client close failed",
            operation: { await client.close() }
        ),
        "closeAfterTest requires an AsyncTestCleanupTrait scope"
    )
}

/// Registers terminal session cleanup with the active test scope.
func closeAfterTest(_ session: InitializedMCPClientSession) {
    precondition(
        registerAsyncTestCleanup(
            description: "initialized MCP session close failed",
            operation: { await session.close() }
        ),
        "closeAfterTest requires an AsyncTestCleanupTrait scope"
    )
}

