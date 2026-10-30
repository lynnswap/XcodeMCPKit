import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeLaunchOwnershipTests {
    @Test @MainActor func sessionsKeepTheirRequestOwnershipWithoutTaskLocalState() async throws {
        let ownership = NativeLaunchOwnership()
        let first = NativeExecutionOperations.Scope()
        let second = NativeExecutionOperations.Scope()
        let tracker = NSObject()
        let session = NSObject()
        let unrelated = NSObject()
        ownership.register(tracker, scope: first)
        ownership.register(unrelated, scope: second)
        let inherited = try #require(ownership.scope(for: tracker))
        ownership.register(session, scope: inherited)
        #expect(ownership.scope(for: session) === first)
        #expect(ownership.scope(for: unrelated) === second)
        try await first.finish()
        #expect(ownership.scope(for: session) == nil)
        #expect(ownership.scope(for: unrelated) === second)
    }

    @Test @MainActor func aLauncherCreatedBeforeTrackerAssignmentFindsItsOwnerAtPIDDelivery() async throws {
        let ownership = NativeLaunchOwnership()
        let scope = NativeExecutionOperations.Scope()
        let session = NSObject()
        let launcher = NSObject()
        let template = NativeApplicationLaunch(processIdentifier: 0, simulatorIdentifier: UUID())
        ownership.registerLauncher(launcher, session: session, scope: nil, launch: template)
        #expect(ownership.launch(for: launcher) == nil)
        ownership.register(session, scope: scope)
        let owned = try #require(ownership.launch(for: launcher))
        #expect(owned.scope === scope)
        #expect(owned.launch.simulatorIdentifier == template.simulatorIdentifier)
        try await scope.finish()
        #expect(ownership.launch(for: launcher) == nil)
    }

    @Test func ownershipDoesNotRetainTrackersOrRequests() {
        let ownership = NativeLaunchOwnership()
        weak var released: NSObject?
        do {
            let tracker = NSObject()
            released = tracker
            ownership.register(tracker, scope: NativeExecutionOperations.Scope())
            #expect(ownership.scope(for: tracker) == nil)
        }
        #expect(released == nil)
    }
}
