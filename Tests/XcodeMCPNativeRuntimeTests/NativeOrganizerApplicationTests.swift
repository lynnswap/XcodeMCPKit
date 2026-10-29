import AppKit
import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeOrganizerApplicationTests {
    @Test func recoveredApplicationRequiresEveryIdentityFieldBeforeTermination() async throws {
        let saved = identity()
        let differentApplications = [
            Application(identifier: 124),
            Application(appPath: "/other/Xcode.app"),
            Application(launchSeconds: 101),
            Application(terminated: true),
        ]
        var terminated = false
        for current in differentApplications {
            try await NativeOrganizerApplication.shutdownRecovered(saved, application: { _ in current }, shutdown: { _ in
                terminated = true
            })
        }
        try await NativeOrganizerApplication.shutdownRecovered(saved, application: { _ in nil }, shutdown: { _ in
            terminated = true
        })
        #expect(!terminated)
    }

    @Test func matchingRecoveredApplicationPreservesItsShutdownFailure() async throws {
        let current = Application()
        var received: NSRunningApplication?
        let failure = NSError(domain: "OrganizerRecoveryTest", code: 7)
        do {
            try await NativeOrganizerApplication.shutdownRecovered(identity(), application: { identifier in
                #expect(identifier == current.processIdentifier)
                return current
            }, shutdown: { application in
                received = application
                throw failure
            })
            Issue.record("A failed Organizer shutdown was returned as success")
        } catch {
            #expect(error as NSError === failure)
        }
        #expect(received === current)
    }

    @Test func anAlreadyTerminatedOrganizerDoesNotLookUpAReusedPID() async throws {
        // Termination is already confirmed even if AppKit no longer provides
        // all of the departed process's identity metadata.
        try await NativeOrganizerApplication.shutdownRecovered(.object(["terminated": .bool(true)]), application: { _ in
            Issue.record("An already terminated Organizer must not resolve its old PID")
            return Application()
        }, shutdown: { _ in
            Issue.record("An already terminated Organizer must not be terminated again")
        })
    }

    @Test func incompleteRecoveredIdentityFailsBeforeLookingUpAnApplication() async throws {
        guard case .object(var saved) = identity() else { return }
        saved["launchDate"] = .null
        await #expect(throws: (any Error).self) {
            try await NativeOrganizerApplication.shutdownRecovered(.object(saved), application: { _ in
                Issue.record("An incomplete identity cannot identify an owned process")
                return Application()
            }, shutdown: { _ in
                Issue.record("An incomplete identity cannot authorize termination")
            })
        }
    }

    private func identity(terminated: Bool = false) -> JSONValue {
        .object(["processId": .number(.int(123)), "appPath": .string("/example/Xcode.app"),
                 "launchDate": .number(.double(100)), "terminated": .bool(terminated)])
    }

    private final class Application: NSRunningApplication, @unchecked Sendable {
        private let identifier: pid_t
        private let path: String
        private let launchSeconds: Double
        private let finished: Bool

        init(identifier: pid_t = 123, appPath: String = "/example/Xcode.app",
             launchSeconds: Double = 100, terminated: Bool = false) {
            self.identifier = identifier
            path = appPath
            self.launchSeconds = launchSeconds
            finished = terminated
            super.init()
        }

        override var processIdentifier: pid_t { identifier }
        override var bundleURL: URL? { URL(filePath: path) }
        override var launchDate: Date? { Date(timeIntervalSince1970: launchSeconds) }
        override var isTerminated: Bool { finished }
    }
}
