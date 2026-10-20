import AppKit
import Foundation
import XcodeMCPCore
import XcodeMCPInstallation

typealias XcodeHostInstallation = XcodeInstallation

extension XcodeInstallation {
    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "appPath": .string(appURL.path),
            "developerDirectory": .string(developerDirectory.path),
        ]
        if let version { fields["xcodeVersion"] = .string(version) }
        return fields
    }
}

struct XcodeGUIProcess: Sendable, Equatable {
    struct Identity: Hashable, Sendable {
        let processID: pid_t
        let launchDate: Date
        let developerDirectory: URL
    }

    let processID: pid_t
    let launchDate: Date
    let installation: XcodeHostInstallation

    var identity: Identity {
        Identity(processID: processID, launchDate: launchDate,
                 developerDirectory: installation.developerDirectory)
    }

    static func running() -> [Self] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .compactMap(snapshot)
            .sorted { $0.processID < $1.processID }
    }

    private static func snapshot(_ application: NSRunningApplication) -> Self? {
        guard !application.isTerminated, let url = application.bundleURL,
              let launchDate = application.launchDate else { return nil }
        return Self(processID: application.processIdentifier, launchDate: launchDate,
                    installation: XcodeHostInstallation(developerDirectory: url))
    }

    var isRunning: Bool {
        guard let application = NSRunningApplication(processIdentifier: processID),
              application.bundleIdentifier == "com.apple.dt.Xcode",
              let current = Self.snapshot(application) else { return false }
        return current.identity == identity
    }
}

struct XcodeHostInventory: Sendable {
    let defaultInstallation: XcodeHostInstallation
    let discover: @Sendable () async throws -> [XcodeHostInstallation]
    let runningGUIProcesses: @Sendable () -> [XcodeGUIProcess]
    let isGUIProcessRunning: @Sendable (XcodeGUIProcess) -> Bool

    init(defaultInstallation: XcodeHostInstallation,
         runningGUIProcesses: @escaping @Sendable () -> [XcodeGUIProcess] = { [] },
         isGUIProcessRunning: @escaping @Sendable (XcodeGUIProcess) -> Bool = { $0.isRunning },
         discover: @escaping @Sendable () async throws -> [XcodeHostInstallation]) {
        self.defaultInstallation = defaultInstallation
        self.discover = discover
        self.runningGUIProcesses = runningGUIProcesses
        self.isGUIProcessRunning = isGUIProcessRunning
    }

    static func live(
        configuration: ProxyRuntimeConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let discovery = XcodeInstallationDiscovery.live
        let logger = ProxyLogging.make("installation")
        let installation = try discovery.resolve(preferred: configuration.developerDirectoryURL, environment: environment) {
            logger.notice("\($0)")
        }
        logger.info("Selected Xcode", metadata: ["app_path": .string(installation.appURL.path)])
        return Self(defaultInstallation: installation, runningGUIProcesses: XcodeGUIProcess.running) {
            discovery.discover { logger.notice("\($0)") }
        }
    }
}

struct NativeHostBrokerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
