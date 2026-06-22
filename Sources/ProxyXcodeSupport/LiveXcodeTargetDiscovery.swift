import AppKit
import Foundation
import ProxyCore

package struct LiveXcodeTargetDiscovery: XcodeTargetDiscovering, Sendable {
    package init() {}

    package func runningXcodeTargets() -> [DocumentationProviderTarget] {
        var targetsByPID: [pid_t: DocumentationProviderTarget] = [:]

        for application in NSWorkspace.shared.runningApplications {
            guard application.bundleIdentifier == "com.apple.dt.Xcode",
                  application.isTerminated == false,
                  let bundlePath = application.bundleURL?.path else {
                continue
            }
            if let target = Self.target(processID: application.processIdentifier, appPath: bundlePath) {
                targetsByPID[target.processID] = target
            }
        }

        for processID in ProcessEnumeration.processIDs(named: "Xcode") {
            if targetsByPID[processID] != nil {
                continue
            }
            guard let processPath = ProcessEnumeration.executablePath(of: processID),
                  let appPath = Self.appPath(fromExecutablePath: processPath),
                  let target = Self.target(processID: processID, appPath: appPath) else {
                continue
            }
            targetsByPID[target.processID] = target
        }

        return targetsByPID.values.sorted { lhs, rhs in
            if lhs.appPath == rhs.appPath {
                return lhs.processID < rhs.processID
            }
            return lhs.appPath < rhs.appPath
        }
    }

    private static func target(processID: pid_t, appPath: String) -> DocumentationProviderTarget? {
        let developerDir = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Developer")
            .path
        let mcpbridgePath = URL(fileURLWithPath: developerDir)
            .appendingPathComponent("usr/bin/mcpbridge")
            .path
        guard FileManager.default.isExecutableFile(atPath: mcpbridgePath) else {
            return nil
        }
        let xcodeVersion = Self.xcodeVersion(appPath: appPath)
        return DocumentationProviderTarget(
            processID: processID,
            appPath: appPath,
            developerDir: developerDir,
            mcpbridgePath: mcpbridgePath,
            xcodeVersion: xcodeVersion
        )
    }

    private static func xcodeVersion(appPath: String) -> String {
        guard let bundle = Bundle(url: URL(fileURLWithPath: appPath)) else {
            return ""
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""
    }

    private static func appPath(fromExecutablePath path: String) -> String? {
        guard let range = path.range(of: "/Contents/MacOS/Xcode") else {
            return nil
        }
        return String(path[..<range.lowerBound])
    }

}
