import AppKit
import Darwin
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativeOrganizerApplication {
    let application: NSRunningApplication
    let processIdentifier: pid_t
    private let appURL: URL
    private let launchDate: Date?
    private let sendEvent: (NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions) throws -> Void

    init(application: NSRunningApplication, appURL: URL, launchDate: Date?,
         sendEvent: @escaping (NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions) throws -> Void = { event, options in
             _ = try event.sendEvent(options: options, timeout: NSAppleEventTimeOutDefault)
         }) {
        self.application = application
        processIdentifier = application.processIdentifier
        self.appURL = appURL
        self.launchDate = launchDate
        self.sendEvent = sendEvent
    }

    static func launch(installation: NativeXcodeInstallation,
        runningApplications: () -> [NSRunningApplication] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
        },
        open: (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication = { url, configuration in
            try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }) async throws -> NativeOrganizerApplication {
        try Task.checkCancellation()
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let existingPIDs = Set(runningApplications().filter { !$0.isTerminated }.map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        configuration.activates = false
        configuration.hides = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        let application = try await open(appURL, configuration)
        guard !existingPIDs.contains(application.processIdentifier), application.processIdentifier > 0,
              application.bundleURL?.resolvingSymlinksInPath() == appURL else {
            throw failure(code: 1, processIdentifier: application.processIdentifier,
                          message: "Xcode did not return a new Organizer application owned by this request; no termination was requested")
        }
        return NativeOrganizerApplication(application: application, appURL: appURL, launchDate: application.launchDate)
    }

    func open(_ url: URL) throws {
        try Task.checkCancellation()
        guard !application.isTerminated else {
            throw Self.failure(code: 1, processIdentifier: processIdentifier,
                               message: "The owned Organizer application ended before receiving its URL")
        }
        try validateIdentity()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        try sendEvent(event, [.noReply, .neverInteract])
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
        if case .object(var fields) = identity, case .string(let path) = fields["ownerLeasePath"] {
            let lease: FileHandle
            do { lease = try FileHandle(forUpdating: URL(filePath: path)) }
            catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
                fields["ownerLeasePath"] = nil
                try await shutdownRecovered(.object(fields), application: application, shutdown: shutdown)
                return
            }
            let acquired = flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0
            let code = errno
            let outcome: Result<Void, any Error>
            do {
                if acquired {
                    fields["ownerLeasePath"] = nil
                    try await shutdownRecovered(.object(fields), application: application, shutdown: shutdown)
                } else if code != EWOULDBLOCK {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                outcome = .success(())
            } catch { outcome = .failure(error) }
            do { try lease.close() }
            catch {
                if case .failure(let original) = outcome {
                    throw NSError(domain: "XcodeMCPKit.OrganizerApplication", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Organizer recovery and owner lease cleanup failed",
                        NSMultipleUnderlyingErrorsKey: [original as NSError, error as NSError],
                    ])
                }
                throw error
            }
            try outcome.get()
            return
        }
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
        try validateIdentity()
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

    private func validateIdentity() throws {
        guard application.processIdentifier == processIdentifier,
              application.bundleURL?.resolvingSymlinksInPath() == appURL,
              application.launchDate == launchDate else {
            throw Self.failure(code: 1, processIdentifier: processIdentifier,
                               message: "The owned Organizer application's identity changed; no operation was requested")
        }
    }

    private static func failure(code: Int, processIdentifier: pid_t, message: String) -> NSError {
        NSError(domain: "XcodeMCPKit.OrganizerApplication", code: code, userInfo: [
            NSLocalizedDescriptionKey: "\(message) (PID \(processIdentifier))",
            "processIdentifier": processIdentifier,
        ])
    }
}
