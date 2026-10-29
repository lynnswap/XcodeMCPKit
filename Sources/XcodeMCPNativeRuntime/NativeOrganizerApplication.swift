import AppKit
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativeOrganizerApplication {
    let application: NSRunningApplication
    let processIdentifier: pid_t
    private let appURL: URL
    private let launchDate: Date?

    private init(application: NSRunningApplication, appURL: URL, launchDate: Date?) {
        self.application = application
        processIdentifier = application.processIdentifier
        self.appURL = appURL
        self.launchDate = launchDate
    }

    static func launch(installation: NativeXcodeInstallation, url: URL) async throws -> NativeOrganizerApplication {
        try Task.checkCancellation()
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .filter { !$0.isTerminated }.map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        configuration.activates = true
        configuration.addsToRecentItems = false
        let application = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        guard !existingPIDs.contains(application.processIdentifier), application.processIdentifier > 0,
              application.bundleURL?.resolvingSymlinksInPath() == appURL else {
            throw failure(code: 1, processIdentifier: application.processIdentifier,
                          message: "Xcode did not return a new Organizer application owned by this request; no termination was requested")
        }
        return NativeOrganizerApplication(application: application, appURL: appURL, launchDate: application.launchDate)
    }

    static func shutdownRecovered(_ identity: JSONValue,
        application: (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) },
        shutdown: (NSRunningApplication) async throws -> Void = { application in
            guard let appURL = application.bundleURL else {
                throw failure(code: 1, processIdentifier: application.processIdentifier,
                              message: "The recovered Organizer application has no bundle URL")
            }
            try await NativeOrganizerApplication(application: application,
                appURL: appURL.resolvingSymlinksInPath(), launchDate: application.launchDate).shutdown()
        }) async throws {
        if case .object(let fields) = identity, fields["terminated"] == .bool(true) { return }
        guard case .object(let fields) = identity,
              case .number(.int(let identifier)) = fields["processId"],
              let pid = pid_t(exactly: identifier), pid > 0,
              case .string(let appPath) = fields["appPath"], appPath.hasPrefix("/"),
              case .number(let launchDate) = fields["launchDate"] else {
            throw NativeRuntimeError.unsupportedContract("The saved Organizer process identity is incomplete; no termination was requested")
        }
        let seconds: Double
        switch launchDate {
        case .int(let value): seconds = Double(value)
        case .double(let value): seconds = value
        }
        guard seconds.isFinite else {
            throw NativeRuntimeError.unsupportedContract("The saved Organizer launch date is invalid; no termination was requested")
        }
        // A PID may have been reused after the owner exited. Only the original
        // application instance may receive a termination request during recovery.
        guard let current = application(pid), !current.isTerminated,
              current.processIdentifier == pid,
              current.bundleURL?.resolvingSymlinksInPath().path == appPath,
              current.launchDate?.timeIntervalSince1970 == seconds else { return }
        try await shutdown(current)
    }

    func shutdown() async throws {
        if application.isTerminated { return }
        guard application.processIdentifier == processIdentifier,
              application.bundleURL?.resolvingSymlinksInPath() == appURL,
              application.launchDate == launchDate else {
            throw Self.failure(code: 1, processIdentifier: processIdentifier,
                               message: "The owned Organizer application's identity changed; no termination was requested")
        }
        guard application.terminate() || application.isTerminated else {
            throw Self.failure(code: 2, processIdentifier: processIdentifier,
                               message: "The owned Organizer application refused the termination request")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !application.isTerminated {
            guard clock.now < deadline else {
                throw Self.failure(code: 3, processIdentifier: processIdentifier,
                                   message: "The owned Organizer application did not terminate within 10 seconds")
            }
            try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(100)), deadline))
        }
    }

    private static func failure(code: Int, processIdentifier: pid_t, message: String) -> NSError {
        NSError(domain: "XcodeMCPKit.OrganizerApplication", code: code, userInfo: [
            NSLocalizedDescriptionKey: "\(message) (PID \(processIdentifier))",
            "processIdentifier": processIdentifier,
        ])
    }
}
