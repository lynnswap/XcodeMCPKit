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

    @Test func aMatchingLegacyOwnerIsTerminatedByRecovery() async throws {
        let current = Application()
        try await NativeOrganizerApplication.shutdownRecovered(identity(), application: { _ in current })
        #expect(current.terminationRequests == 1)
        #expect(current.isTerminated)
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

    @Test func theActiveMatchingXcodeIsPreferredWithoutStartingAnotherInstance() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let appPath = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
        let inactive = Application(identifier: 10, appPath: appPath)
        let active = Application(identifier: 11, appPath: appPath, active: true)
        let anotherInstallation = Application(identifier: 12, appPath: "/other/Xcode.app", active: true)
        let borrowed = try NativeOrganizerApplication.running(installation: installation,
            runningApplications: { [anotherInstallation, inactive, active] })
        #expect(borrowed.application === active)
        #expect(inactive.terminationRequests == 0)
        #expect(active.terminationRequests == 0)
    }

    @Test func aSingleInactiveXcodeCanBeUsedButMissingOrAmbiguousInstancesCannot() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let appPath = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
        let current = Application(appPath: appPath)
        let borrowed = try NativeOrganizerApplication.running(installation: installation, runningApplications: { [current] })
        #expect(borrowed.application === current)
        for applications in [[], [Application(appPath: "/other/Xcode.app")],
                             [Application(appPath: appPath, terminated: true)],
                             [current, Application(identifier: 124, appPath: appPath)]] {
            #expect(throws: (any Error).self) {
                try NativeOrganizerApplication.running(installation: installation, runningApplications: { applications })
            }
        }
        #expect(current.terminationRequests == 0)
    }

    @Test func borrowedAndPreservedApplicationsNeverEnterLegacyTermination() async throws {
        guard case .object(var borrowed) = identity() else { return }
        borrowed["ownership"] = .string("borrowed")
        let cases: [(JSONValue, Set<pid_t>)] = [(.object(borrowed), []), (identity(), [123])]
        for (saved, preserved) in cases {
            try await NativeOrganizerApplication.shutdownRecovered(saved, preservingProcessIdentifiers: preserved,
                application: { _ in
                    Issue.record("A borrowed or preserved Xcode must not be resolved for termination")
                    return Application()
                }, shutdown: { _ in Issue.record("A borrowed or preserved Xcode must not be terminated") })
        }
    }

    @Test func foregroundEditingDefersOrganizerRoutesAndWaitingCanBeCancelled() async throws {
        let application = Application(active: true)
        var delivered = false
        let borrowed = NativeOrganizerApplication(application: application,
            appURL: URL(filePath: "/example/Xcode.app"), launchDate: application.launchDate,
            sendEvent: { _, _ in delivered = true })
        let task = Task { @MainActor in
            try await borrowed.waitUntilInactive()
            try borrowed.open(URL(string: "xcode://organizer/crashes/listPoints")!)
        }
        await Task.yield()
        #expect(!delivered)
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancellation while waiting for foreground editing must remain observable")
        } catch { #expect(error is CancellationError) }
        #expect(!delivered)
        #expect(application.terminationRequests == 0)
    }

    @Test func routeEventsTargetOnlyTheBorrowedPIDWithoutInteraction() throws {
        let application = Application()
        let urls = [URL(string: "xcode://organizer/crashes/listPoints?timePeriod=last14Days")!,
                    URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=stable-id")!]
        var delivered: [String] = []
        let borrowed = NativeOrganizerApplication(application: application,
            appURL: URL(filePath: "/example/Xcode.app"), launchDate: application.launchDate,
            sendEvent: { event, options in
                #expect(event.eventClass == AEEventClass(kInternetEventClass))
                #expect(event.eventID == AEEventID(kAEGetURL))
                let target = try #require(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
                #expect(target.descriptorType == DescType(typeKernelProcessID))
                #expect(target.data == NSAppleEventDescriptor(processIdentifier: application.processIdentifier).data)
                #expect(options == [.noReply, .neverInteract, .init(rawValue: UInt(kAEDoNotPromptForUserConsent))])
                delivered.append(try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue))
            })
        for url in urls { try borrowed.open(url) }
        #expect(delivered == urls.map(\.absoluteString))

        let mismatched = NativeOrganizerApplication(application: application,
            appURL: URL(filePath: "/other/Xcode.app"), launchDate: application.launchDate,
            sendEvent: { _, _ in Issue.record("A changed application identity must not receive a URL") })
        #expect(throws: (any Error).self) { try mismatched.open(urls[0]) }
    }

    @Test func differentAndRepeatedRoutesReuseXcodeWithoutSavingOwnershipOrTerminatingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let organizer = root.appending(component: "Organizer")
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let application = Application(appPath: appURL.path)
        var delivered: [String] = []
        let borrowed = NativeOrganizerApplication(application: application, appURL: appURL,
            launchDate: application.launchDate, sendEvent: { event, _ in
                delivered.append(try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue))
            })
        let service = NativeOrganizerCrashService(installation: installation, organizerRoot: organizer,
                                                 runningOrganizer: { _ in borrowed })
        let firstURL = URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=first")!
        let secondURL = URL(string: "xcode://organizer/crashes/downloadPoint?analyticsPointId=second")!
        for url in [firstURL, secondURL, firstURL] {
            #expect(try await service.organizerApplication(for: url) === borrowed)
        }
        #expect(delivered == [firstURL, secondURL, firstURL].map(\.absoluteString))
        #expect(try FileManager.default.contentsOfDirectory(at: organizer.appending(component: "Owners"),
                                                          includingPropertiesForKeys: nil).isEmpty)
        try await service.shutdown()
        #expect(application.terminationRequests == 0)
        #expect(!application.isTerminated)
    }

    @Test func legacyRecoveryWaitsForItsLeaseAndPreservesTheBorrowedXcode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let organizer = root.appending(component: "Organizer")
        let legacy = organizer.appending(path: "Owners/legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let lock = legacy.appending(component: "owner.lock")
        try Data().write(to: lock)
        try NativeCrashStore.encode(identity()).write(to: legacy.appending(component: "owner.json"))
        let lease = try FileHandle(forUpdating: lock)
        defer { try? lease.close() }
        #expect(flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
        try Data().write(to: organizer.appending(path: "Owners/.DS_Store"))
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let departed = Application()
        let current = Application(identifier: 124, appPath: appURL.path)
        let borrowed = NativeOrganizerApplication(application: current, appURL: appURL,
            launchDate: current.launchDate, sendEvent: { _, _ in })
        var reclaimed: [JSONValue] = []
        let service = NativeOrganizerCrashService(installation: installation, organizerRoot: organizer,
            runningOrganizer: { _ in borrowed }, recoverApplication: { saved, preserved in
                reclaimed.append(saved)
                #expect(preserved == [current.processIdentifier])
                try await NativeOrganizerApplication.shutdownRecovered(saved, preservingProcessIdentifiers: preserved,
                    application: { _ in departed }, shutdown: { #expect($0.terminate()) })
            })
        let url = URL(string: "xcode://organizer/crashes/listPoints")!
        _ = try await service.organizerApplication(for: url)
        #expect(reclaimed.isEmpty)
        #expect(!departed.isTerminated)
        try lease.close()
        _ = try await service.organizerApplication(for: url)
        #expect(reclaimed.count == 1)
        #expect(departed.isTerminated)
        try await service.shutdown()
        #expect(current.terminationRequests == 0)
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

    @Test(arguments: [false, true])
    func preparationFailureRecoversSavedScopeButCancellationDoesNot(cancelled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try installation(at: root)
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let application = Application(appPath: appURL.path)
        let failure: any Error = cancelled ? CancellationError() : NSError(domain: "OrganizerURLDelivery", code: 7)
        let products = root.appending(component: "Products")
        let service = NativeOrganizerCrashService(installation: installation,
            cache: NativeOrganizerCrashCache(productsRoot: products), organizerRoot: root.appending(component: "Organizer"),
            runningOrganizer: { _ in
                NativeOrganizerApplication(application: application, appURL: appURL,
                    launchDate: application.launchDate, sendEvent: { _, _ in throw failure })
            })
        let request = NativeCrashServiceQuery(query: NativeCrashQuery(bundleIdentifier: "example.App",
            platformIdentifier: "com.apple.platform.iphoneos", uploadPlatformIdentifier: "com.apple.platform.iphoneos",
            appVersion: nil, isBeta: nil, timePeriod: "last365Days", pageIndex: 0, pageSize: 25), adamIdentifier: "123")
        let scope = products.appending(path: "example.App/Crashes/Points/stable-id.xccrashpoint/Filters/all")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let point: JSONValue = .object(["pointIdentifier": .object([
            "uploadPlatformSDKIdentifier": .string(request.query.uploadPlatformIdentifier),
            "selectableAnalyticsPointIdentifier": .object([
                "reportTypeIdentifier": .string("Xcode.Analytics.ReportType.CrashPoint"),
                "analyticsPointIdentifier": .string("stable-id"), "adamIdentifier": .string("123"),
                "bundleIdentifier": .string("example.App"), "platformSDKIdentifier": .string(request.query.platformIdentifier),
            ]),
        ])])
        let distribution: JSONValue = .object(["header": .object([
            "analyticsPointIdentifier": .string("stable-id"), "adamIdentifier": .string("123"),
            "bundleIdentifier": .string("example.App"), "lastRefresh": .string("2024-01-01T00:00:00Z"),
        ]), "body": .object([:])])
        try NativeCrashStore.encode(point).write(to: scope.appending(component: "PointInfo.json"))
        try NativeCrashStore.encode(distribution).write(to: scope.appending(component: "DistributionInfo.json"))
        do {
            let recovered = try await service.fetchIssue(request, issueID: "stable-id")
            #expect(!cancelled)
            #expect(recovered.source == "organizerCache")
            #expect(!recovered.isComplete)
            #expect(recovered.fetchedAt == nil)
            #expect(try nativeTestField(recovered.value, "sampleFreshness") == .string("unverifiedSavedSamples"))
            guard case .string(let directory) = try nativeTestField(recovered.value, "logDirectory") else {
                Issue.record("Recovered samples must keep their saved log directory")
                return
            }
            let logDirectory = URL(filePath: directory)
            #expect(logDirectory.lastPathComponent == "Logs")
            #expect(logDirectory.deletingLastPathComponent().resolvingSymlinksInPath() == scope.resolvingSymlinksInPath())
            #expect(recovered.errors.count == 1)
            #expect(try nativeTestField(recovered.errors[0], "message") == .string((failure as NSError).localizedDescription))
        } catch {
            if cancelled { #expect(error is CancellationError) }
            else { throw error }
        }
        try await service.shutdown()
        #expect(application.terminationRequests == 0)
        #expect(!application.isTerminated)
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
        private let simulatedActive: Bool
        var permitsTermination = true
        private(set) var terminationRequests = 0

        init(identifier: pid_t = 123, appPath: String = "/example/Xcode.app",
             launchSeconds: Double = 100, terminated: Bool = false, active: Bool = false) {
            self.identifier = identifier
            path = appPath
            self.launchSeconds = launchSeconds
            finished = terminated
            simulatedActive = active
            super.init()
        }

        override var processIdentifier: pid_t { identifier }
        override var bundleURL: URL? { URL(filePath: path) }
        override var launchDate: Date? { Date(timeIntervalSince1970: launchSeconds) }
        override var isTerminated: Bool { finished }
        override var isActive: Bool { simulatedActive }
        override func terminate() -> Bool {
            terminationRequests += 1
            if permitsTermination { finished = true }
            return permitsTermination
        }
    }
}
