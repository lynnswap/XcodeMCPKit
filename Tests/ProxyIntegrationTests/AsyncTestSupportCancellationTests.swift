import Testing
@testable import class XcodeMCPCoreTestSupport.AsyncResourceGate
import XcodeMCPProxyTestSupport

@Suite(.asyncTestCleanup)
struct AsyncTestSupportCancellationTests {
    enum PendingWait: CaseIterable, Sendable {
        case signal, lockedValues, indexedValues, matchingValues, gate, keyedGate, keyedGateObservation, resource
    }

    @Test(arguments: PendingWait.allCases)
    func cancellationBeforeRegistrationDoesNotSuspend(wait: PendingWait) async throws {
        let signal = TestSignal()
        let lockedValues = LockedRecordedValues<Int>()
        let values = RecordedValues<Int>()
        let gate = AsyncGate()
        let keyedGate = OperationGate<String>()
        let resource = AsyncResourceGate()
        let resourceHeld = TestSignal()
        let releaseResource = AsyncGate()
        let resourceHolder = wait == .resource ? Task {
            try await resource.withAccess {
                resourceHeld.signal()
                await releaseResource.waitIgnoringCancellation()
            }
        } : nil
        registerAsyncTestCleanup(description: "release cancellation-test resource owner") {
            await releaseResource.signal()
            resourceHolder?.cancel()
            _ = try? await resourceHolder?.value
        }
        if resourceHolder != nil {
            try await resourceHeld.wait(description: "resource owner acquired its permit")
        }
        let task = Task {
            unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
            do {
                switch wait {
                case .signal: try await signal.waitUntilSignaled()
                case .lockedValues: _ = try await lockedValues.nextValue(at: 0)
                case .indexedValues: _ = try await values.nextValue(at: 0)
                case .matchingValues: _ = try await values.nextValue { $0 == 1 }
                case .gate: try await gate.wait()
                case .keyedGate: try await keyedGate.wait(for: "key")
                case .keyedGateObservation: try await keyedGate.waitUntilWaiting(for: "key", count: 1)
                case .resource: try await resource.withAccess {}
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelledWithoutRelease: Bool
        do {
            cancelledWithoutRelease = try await waitWithTimeout("cancelled waiter should complete before release", timeout: .seconds(2)) {
                await task.value
            }
        } catch {
            cancelledWithoutRelease = false
        }
        signal.signal()
        lockedValues.append(1)
        await values.append(1)
        await gate.signal()
        let observationRelease = Task { try? await keyedGate.wait(for: "key") }
        try await keyedGate.waitUntilWaiting(for: "key", count: 1)
        await keyedGate.release("key", count: 2)
        _ = await observationRelease.value
        await releaseResource.signal()
        _ = try await resourceHolder?.value
        _ = await task.value
        #expect(cancelledWithoutRelease)
    }
}
