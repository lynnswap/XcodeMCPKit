import AppKit
import Foundation
import XcodeMCPCore

struct XcodeHostInstallation: Sendable, Equatable {
    let developerDirectory: URL
    let appURL: URL
    let version: String?

    init(developerDirectory: URL) {
        var directory = developerDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if directory.pathExtension == "app" {
            directory.appendPathComponent("Contents/Developer", isDirectory: true)
        }
        self.developerDirectory = directory
        self.appURL = directory.deletingLastPathComponent().deletingLastPathComponent()
        self.version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "appPath": .string(appURL.path),
            "developerDirectory": .string(developerDirectory.path),
        ]
        if let version { fields["xcodeVersion"] = .string(version) }
        return fields
    }
}

struct XcodeHostInventory: Sendable {
    let defaultInstallation: XcodeHostInstallation
    let discover: @Sendable () async throws -> [XcodeHostInstallation]

    static func live(
        configuration: ProxyRuntimeConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let directory: URL
        if let explicit = configuration.developerDirectoryURL {
            directory = explicit
        } else if let value = environment["DEVELOPER_DIR"], !value.isEmpty {
            directory = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["-p"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NativeHostBrokerError("xcode-select could not resolve the default Xcode")
            }
            directory = URL(fileURLWithPath: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        }
        return Self(defaultInstallation: XcodeHostInstallation(developerDirectory: directory)) {
            await MainActor.run {
                NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode")
                    .map { XcodeHostInstallation(developerDirectory: $0) }
            }
        }
    }
}

struct NativeHostBrokerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
