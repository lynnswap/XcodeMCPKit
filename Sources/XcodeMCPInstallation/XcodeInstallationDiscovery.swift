import AppKit
import Foundation

package struct XcodeInstallationDiscovery: Sendable {
    package var selectedDeveloperDirectory: @Sendable () throws -> URL?
    package var registeredApplications: @Sendable () -> [URL]
    package var metadataApplications: @Sendable () throws -> [URL]
    package var applicationDirectories: [URL]
    package var systemVersion: OperatingSystemVersion

    package init(
        selectedDeveloperDirectory: @escaping @Sendable () throws -> URL?,
        registeredApplications: @escaping @Sendable () -> [URL],
        metadataApplications: @escaping @Sendable () throws -> [URL],
        applicationDirectories: [URL],
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.selectedDeveloperDirectory = selectedDeveloperDirectory
        self.registeredApplications = registeredApplications
        self.metadataApplications = metadataApplications
        self.applicationDirectories = applicationDirectories
        self.systemVersion = systemVersion
    }

    package static var live: Self {
        Self(
            selectedDeveloperDirectory: {
                try systemDeveloperDirectory(environment: ProcessInfo.processInfo.environment)
            },
            registeredApplications: {
                NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            },
            metadataApplications: {
                let data = try command("/usr/bin/mdfind", arguments: ["-0", "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"])
                return data.split(separator: 0).map { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) }
            },
            applicationDirectories: FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        )
    }

    package func resolve(
        required: URL? = nil,
        preferred: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> XcodeInstallation {
        if let required {
            let installation = XcodeInstallation(developerDirectory: required)
            if let reason = installation.unavailabilityReason(on: systemVersion) {
                throw XcodeInstallationDiscoveryError("Selected Xcode is unavailable at \(required.path): \(reason)")
            }
            return installation
        }
        var diagnostics: [String] = []
        var attempted = Set<URL>()
        func available(_ url: URL) -> XcodeInstallation? {
            let installation = XcodeInstallation(developerDirectory: url)
            guard attempted.insert(installation.developerDirectory).inserted else { return nil }
            if let reason = installation.unavailabilityReason(on: systemVersion) {
                let message = "Skipping Xcode selection \(url.path): \(reason)"
                diagnostics.append(message)
                report(message)
                return nil
            }
            return installation
        }
        if let preferred, let installation = available(preferred) { return installation }
        if let value = environment["DEVELOPER_DIR"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let installation = available(URL(fileURLWithPath: value, isDirectory: true)) {
            return installation
        }
        do {
            if let directory = try selectedDeveloperDirectory(), let installation = available(directory) {
                return installation
            }
        } catch {
            diagnostics.append(String(describing: error))
            report("Cannot read the selected developer directory: \(error)")
        }
        let installations = discover(report: report)
        if let installation = installations.first { return installation }
        let detail = diagnostics.isEmpty ? "" : " " + diagnostics.joined(separator: "; ")
        throw XcodeInstallationDiscoveryError("No available Xcode installation with native MCP frameworks was found. Install Xcode or set DEVELOPER_DIR to its app or Contents/Developer directory.\(detail)")
    }

    package func discover(report: @escaping @Sendable (String) -> Void = { _ in }) -> [XcodeInstallation] {
        var applications = registeredApplications()
        do { applications += try metadataApplications() }
        catch { report("Xcode metadata discovery failed: \(error)") }
        for directory in applicationDirectories {
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )
                applications += contents.flatMap { url -> [URL] in
                    if url.pathExtension == "app" {
                        return Bundle(url: url)?.bundleIdentifier == "com.apple.dt.Xcode" ? [url] : []
                    }
                    guard let enumerator = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { path, error in
                            report("Cannot search for Xcode in \(path.path): \(error)")
                            return true
                        }
                    ) else { return [] }
                    return enumerator.compactMap { value -> URL? in
                        guard let app = value as? URL, app.pathExtension == "app",
                              Bundle(url: app)?.bundleIdentifier == "com.apple.dt.Xcode" else { return nil }
                        return app
                    }
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                report("Cannot search for Xcode in \(directory.path): \(error)")
            }
        }
        var seen = Set<URL>()
        return applications.compactMap { url in
            let installation = XcodeInstallation(developerDirectory: url)
            guard seen.insert(installation.developerDirectory).inserted else { return nil }
            if let reason = installation.unavailabilityReason(on: systemVersion) {
                report("Skipping Xcode candidate \(url.path): \(reason)")
                return nil
            }
            return installation
        }.sorted { left, right in
            let order = (left.version ?? "").compare(right.version ?? "", options: .numeric)
            return order == .orderedSame ? left.appURL.path < right.appURL.path : order == .orderedDescending
        }
    }

    static func systemDeveloperDirectory(
        environment: [String: String],
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    ) throws -> URL? {
        var environment = environment
        environment.removeValue(forKey: "DEVELOPER_DIR")
        let data = try command(executableURL.path, arguments: ["-p"], environment: environment)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func command(_ executable: String, arguments: [String], environment: [String: String]? = nil) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw XcodeInstallationDiscoveryError("\(executable) failed (\(process.terminationStatus)): \(message)")
        }
        return data
    }
}

package struct XcodeInstallationDiscoveryError: Error, CustomStringConvertible {
    package let description: String
    package init(_ description: String) { self.description = description }
}
