import AppKit
import Darwin
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

    @Test func aDedicatedLaunchDoesNotActivateAndNeverAdoptsAnExistingApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let appPath = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
        let existing = Application(identifier: 10, appPath: appPath)
        let created = Application(identifier: 11, appPath: appPath)
        let owned = try await NativeOrganizerApplication.launch(installation: installation,
            runningApplications: { [existing] }, open: { url, configuration in
                #expect(url.path == appPath)
                #expect(configuration.createsNewApplicationInstance)
                #expect(!configuration.activates)
                #expect(configuration.hides)
                #expect(!configuration.promptsUserIfNeeded)
                #expect(!configuration.addsToRecentItems)
                return created
            })
        #expect(owned.processIdentifier == created.processIdentifier)
        await #expect(throws: (any Error).self) {
            try await NativeOrganizerApplication.launch(installation: installation,
                runningApplications: { [existing] }, open: { _, _ in existing })
        }
        #expect(existing.terminationRequests == 0)
        try await owned.shutdown()
        #expect(created.isTerminated)
        #expect(!existing.isTerminated)
    }

    @Test func routeEventsTargetOnlyTheOwnedPIDWithoutInteraction() throws {
        let application = Application()
        let urls = [URL(string: "xcode://organizer/crashes/listPoints?timePeriod=last14Days")!,
                    URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=stable-id")!]
        var delivered: [String] = []
        let owned = NativeOrganizerApplication(application: application,
            appURL: URL(filePath: "/example/Xcode.app"), launchDate: application.launchDate,
            sendEvent: { event, options in
                #expect(event.eventClass == AEEventClass(kInternetEventClass))
                #expect(event.eventID == AEEventID(kAEGetURL))
                let target = try #require(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
                #expect(target.descriptorType == DescType(typeKernelProcessID))
                #expect(target.data == NSAppleEventDescriptor(processIdentifier: application.processIdentifier).data)
                #expect(options == [.noReply, .neverInteract])
                delivered.append(try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue))
            })
        for url in urls { try owned.open(url) }
        #expect(delivered == urls.map(\.absoluteString))

        let mismatched = NativeOrganizerApplication(application: application,
            appURL: URL(filePath: "/other/Xcode.app"), launchDate: application.launchDate,
            sendEvent: { _, _ in Issue.record("A changed application identity must not receive a URL") })
        #expect(throws: (any Error).self) { try mismatched.open(urls[0]) }
    }

    @Test func differentRoutesReuseTheOwnedApplicationAndRevisitedRoutesRefreshCold() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let organizer = root.appending(component: "Organizer")
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let appPath = appURL.path
        var applications: [Application] = []
        var targets: [pid_t] = []
        let service = NativeOrganizerCrashService(installation: installation, organizerRoot: organizer,
            launchOrganizer: { _ in
                let application = Application(identifier: pid_t(100 + applications.count), appPath: appPath,
                                              launchSeconds: 100.75)
                applications.append(application)
                return NativeOrganizerApplication(application: application, appURL: appURL,
                    launchDate: application.launchDate, sendEvent: { _, _ in targets.append(application.processIdentifier) })
            })
        let firstURL = URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=first")!
        let secondURL = URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=second")!
        let prefetchedURL = URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=prefetched")!
        let unfetchedURL = URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=unfetched")!
        let oldFetch = Date(timeIntervalSince1970: 99)
        let first = try await service.organizerApplication(for: firstURL, previousFetch: oldFetch)
        let second = try await service.organizerApplication(for: secondURL, previousFetch: oldFetch)
        #expect(first === second)
        #expect(!first.application.isTerminated)
        let prefetched = try await service.organizerApplication(for: prefetchedURL,
            previousFetch: Date(timeIntervalSince1970: 100))
        #expect(prefetched !== first)
        #expect(first.application.isTerminated)
        let unfetched = try await service.organizerApplication(for: unfetchedURL)
        #expect(unfetched === prefetched)
        #expect(!prefetched.application.isTerminated)
        let refreshed = try await service.organizerApplication(for: prefetchedURL)
        #expect(refreshed !== prefetched)
        #expect(prefetched.application.isTerminated)
        #expect(applications.count == 3)
        #expect(targets == [100, 100, 101, 101, 102])
        let records = try FileManager.default.contentsOfDirectory(at: organizer.appending(component: "Owners"),
                                                                 includingPropertiesForKeys: nil)
        let record = try NativeCrashStore.object(Data(contentsOf: try #require(records.first).appending(component: "owner.json")))
        #expect(record["processId"] == .number(.int(102)))
        #expect(record["ownerLeasePath"] == nil)
        try await service.shutdown()
        #expect(refreshed.application.isTerminated)
        #expect(try FileManager.default.contentsOfDirectory(at: organizer.appending(component: "Owners"),
                                                          includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func onlyAnOwnerWhoseLeaseEndedIsReclaimedBeforeAnotherAcquisition() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let organizer = root.appending(component: "Organizer")
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let appPath = appURL.path
        let departedApplication = Application(identifier: 123, appPath: appPath)
        var departed: NativeOrganizerCrashService? = NativeOrganizerCrashService(installation: installation,
            organizerRoot: organizer, launchOrganizer: { _ in
                NativeOrganizerApplication(application: departedApplication, appURL: appURL,
                    launchDate: departedApplication.launchDate, sendEvent: { _, _ in })
            })
        _ = try await departed?.organizerApplication(for: URL(string: "xcode://organizer/crashes/listPoints")!)
        try Data().write(to: organizer.appending(path: "Owners/.DS_Store"))
        var reclaimed: [JSONValue] = []
        let currentApplication = Application(identifier: 124, appPath: appPath)
        let observer = NativeOrganizerCrashService(installation: installation, organizerRoot: organizer,
            launchOrganizer: { _ in
                NativeOrganizerApplication(application: currentApplication, appURL: appURL,
                    launchDate: currentApplication.launchDate, sendEvent: { _, _ in })
            }, recoverApplication: { saved in
                reclaimed.append(saved)
                let identifier = try nativeTestField(saved, "processId")
                #expect(identifier == .number(.int(123)))
                #expect(departedApplication.terminate())
            })
        _ = try await observer.organizerApplication(for: URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=first")!)
        #expect(reclaimed.isEmpty)
        #expect(!departedApplication.isTerminated)
        // Simulate host loss: its held owner lease closes while Xcode remains.
        departed = nil
        _ = try await observer.organizerApplication(for: URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=second")!)
        #expect(reclaimed.count == 1)
        #expect(departedApplication.isTerminated)
        #expect(!currentApplication.isTerminated)
        try await observer.shutdown()
    }

    @Test func jobRecoveryDoesNotTerminateAnApplicationStillOwnedByAnotherAcquisition() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appending(component: "owner.lock")
        try Data().write(to: path)
        let lease = try FileHandle(forUpdating: path)
        defer { try? lease.close() }
        #expect(flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
        guard case .object(var saved) = identity() else { return }
        saved["ownerLeasePath"] = .string(path.path)
        let application = Application()
        var terminated = 0
        try await NativeOrganizerApplication.shutdownRecovered(.object(saved), application: { _ in
            Issue.record("An active service lease must be checked before looking up the old job's application")
            return application
        }, shutdown: { _ in terminated += 1 })
        #expect(terminated == 0)
        try lease.close()
        try await NativeOrganizerApplication.shutdownRecovered(.object(saved), application: { _ in application },
            shutdown: { _ in terminated += 1 })
        #expect(terminated == 1)
    }

    @Test func routeDeliveryAndOwnedCleanupFailuresRemainAvailableTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let appPath = appURL.path
        let application = Application(appPath: appPath)
        application.permitsTermination = false
        let failure = NSError(domain: "OrganizerURLDelivery", code: 7)
        let service = NativeOrganizerCrashService(installation: installation, organizerRoot: root.appending(component: "Organizer"),
            launchOrganizer: { _ in
                NativeOrganizerApplication(application: application, appURL: appURL,
                    launchDate: application.launchDate, sendEvent: { _, _ in throw failure })
            })
        let request = NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.iphoneos", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: nil, isBeta: nil, timePeriod: "last365Days", pageIndex: 0, pageSize: 25), adamIdentifier: "123")
        do {
            _ = try await service.fetchIssue(request, issueID: "stable-id")
            Issue.record("Delivery and cleanup failures must not become success")
        } catch {
            let errors = try #require((error as NSError).userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError])
            #expect(errors.count == 2)
            #expect(errors[0] === failure)
            #expect(errors[1].domain == "XcodeMCPKit.OrganizerApplication")
        }
        application.permitsTermination = true
        try await service.shutdown()
    }

    private func installation(at root: URL) throws -> NativeXcodeInstallation {
        let contents = root.appending(path: "Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/IDEFoundation.framework"),
                                               withIntermediateDirectories: true)
        return try NativeXcodeInstallation(developerDirectory: contents.appending(component: "Developer"))
    }

    private func identity(terminated: Bool = false) -> JSONValue {
        .object(["processId": .number(.int(123)), "appPath": .string("/example/Xcode.app"),
                 "launchDate": .number(.double(100)), "terminated": .bool(terminated)])
    }

    private final class Application: NSRunningApplication, @unchecked Sendable {
        private let identifier: pid_t
        private let path: String
        private let launchSeconds: Double
        private var finished: Bool
        var permitsTermination = true
        private(set) var terminationRequests = 0

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
        override func terminate() -> Bool {
            terminationRequests += 1
            if permitsTermination { finished = true }
            return permitsTermination
        }
    }
}
