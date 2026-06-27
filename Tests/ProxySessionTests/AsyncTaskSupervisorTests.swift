import Testing
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyKit

@Suite struct AsyncTaskSupervisorTests {
    @Test func runReportsAcceptedBeforeShutdown() async throws {
        let supervisor = AsyncTaskSupervisor()
        let ran = TestSignal()

        let scheduled = supervisor.run {
            ran.signal()
        }

        #expect(scheduled)
        try await ran.wait(description: "waiting for scheduled task to run")
        await supervisor.shutdown()
    }

    @Test func runReportsRejectedAfterShutdownBegins() async {
        let supervisor = AsyncTaskSupervisor()

        let drain = supervisor.beginShutdown()
        let scheduled = supervisor.run {}

        #expect(scheduled == false)
        await drain.wait()
    }
}
