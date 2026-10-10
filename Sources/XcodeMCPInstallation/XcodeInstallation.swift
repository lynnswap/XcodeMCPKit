import Foundation

package struct XcodeInstallation: Sendable, Equatable {
    package let developerDirectory: URL
    package let appURL: URL
    package let version: String?
    private let minimumSystemVersion: String?

    package init(developerDirectory: URL) {
        var directory = developerDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if directory.pathExtension == "app" {
            directory.append(path: "Contents/Developer", directoryHint: .isDirectory)
        }
        self.developerDirectory = directory
        self.appURL = directory.deletingLastPathComponent().deletingLastPathComponent()
        let bundle = Bundle(url: appURL)
        self.version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.minimumSystemVersion = bundle?.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
    }

    package var contentsDirectory: URL { developerDirectory.deletingLastPathComponent() }

    package func unavailabilityReason(on systemVersion: OperatingSystemVersion) -> String? {
        if let minimumSystemVersion {
            let components = minimumSystemVersion.split(separator: ".").compactMap { Int($0) }
            let required = components + Array(repeating: 0, count: max(0, 3 - components.count))
            let current = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
            if current.lexicographicallyPrecedes(required.prefix(3)) {
                return "requires macOS \(minimumSystemVersion)"
            }
        }
        guard FileManager.default.fileExists(atPath: developerDirectory.path) else {
            return "developer directory does not exist"
        }
        for path in [
            "Frameworks/IDEFoundation.framework", "Frameworks/IDEKit.framework",
            "SharedFrameworks/DVTFoundation.framework", "PlugIns/IDEIntelligenceChat.framework",
            "PlugIns/IDEIntelligenceMessaging.framework",
        ] {
            guard FileManager.default.fileExists(atPath: contentsDirectory.appending(path: path).path) else {
                return "missing \(path)"
            }
        }
        return nil
    }
}
