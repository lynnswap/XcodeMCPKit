import Foundation

enum XcodeTargetMapper {
    static func targets(
        from applications: [RunningApplicationSnapshot]
    ) -> [XcodeProcessTarget] {
        applications.compactMap { application in
            guard application.processID > 0,
                  application.bundleIdentifier == "com.apple.dt.Xcode",
                  application.isTerminated == false,
                  let bundlePath = application.bundlePath
            else {
                return nil
            }
            return target(processID: application.processID, appPath: bundlePath)
        }.sorted { lhs, rhs in
            if lhs.appPath == rhs.appPath {
                return lhs.processID < rhs.processID
            }
            return lhs.appPath < rhs.appPath
        }
    }

    private static func target(processID: pid_t, appPath: String) -> XcodeProcessTarget? {
        let developerDir = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Developer")
            .path
        let mcpbridgePath = URL(fileURLWithPath: developerDir)
            .appendingPathComponent("usr/bin/mcpbridge")
            .path
        guard FileManager.default.isExecutableFile(atPath: mcpbridgePath) else {
            return nil
        }
        let xcodeVersion = xcodeVersion(appPath: appPath)
        return XcodeProcessTarget(
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
}
