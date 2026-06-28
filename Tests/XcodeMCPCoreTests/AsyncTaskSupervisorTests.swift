import Testing
import XcodeMCPKit
@testable import XcodeMCPCoreTestSupport

@Suite struct AsyncTaskSupervisorTests {
    @Test func runReportsAcceptedBeforeShutdown() async throws {
        let supervisor = AsyncTaskSupervisor()
        let ran = RecordedValues<Bool>()

        let scheduled = supervisor.run {
            await ran.append(true)
        }

        #expect(scheduled)
        _ = try await waitWithTimeout("waiting for scheduled task to run") {
            try await ran.nextValue(at: 0)
        }
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
