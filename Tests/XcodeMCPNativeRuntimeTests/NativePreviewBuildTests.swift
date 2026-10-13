import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewBuildTests {
    @Test func respectsActivePlatformUnlessAnExplicitDestinationIsRequested() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = NativePreviewBuild(installation: try NativeXcodeInstallation(developerDirectory: app))
        let mac = PreviewBuildDestination(identifier: "Mac", platform: "com.apple.platform.macosx")
        let ios = PreviewBuildDestination(identifier: UUID().uuidString, platform: "com.apple.platform.iphonesimulator")
        let scheme = PreviewBuildScheme(destinations: [mac, ios])
        let manager = PreviewBuildRunContextManager(scheme: scheme, destination: mac)
        let workspace = PreviewBuildWorkspace(manager: manager)

        #expect(try builder.selectDestination(workspace: workspace) == nil)
        #expect(try builder.selectDestination(workspace: workspace, preferred: ["identifier": ios.targetDevice.identifier]) === ios)
    }
}

private final class PreviewBuildWorkspace: NSObject {
    @objc let runContextManager: PreviewBuildRunContextManager
    init(manager: PreviewBuildRunContextManager) { runContextManager = manager }
}

private final class PreviewBuildRunContextManager: NSObject {
    @objc let activeRunContext: PreviewBuildScheme
    @objc let activeRunDestination: PreviewBuildDestination
    init(scheme: PreviewBuildScheme, destination: PreviewBuildDestination) {
        activeRunContext = scheme
        activeRunDestination = destination
    }
}

private final class PreviewBuildScheme: NSObject {
    @objc let availableRunDestinations: NSArray
    init(destinations: [PreviewBuildDestination]) { availableRunDestinations = NSArray(array: destinations) }
}

private final class PreviewBuildDestination: NSObject {
    @objc let targetDevice: PreviewBuildDevice
    @objc let targetSDK: PreviewBuildSDK
    @objc let effectiveOperatingSystemVersion: NSString = "27.1"
    init(identifier: String, platform: String) {
        targetDevice = PreviewBuildDevice(identifier: identifier)
        targetSDK = PreviewBuildSDK(platform: platform)
    }
}

private final class PreviewBuildDevice: NSObject {
    @objc let identifier: String
    @objc let modelName = "Preview device"
    init(identifier: String) { self.identifier = identifier }
}

private final class PreviewBuildSDK: NSObject {
    @objc let platform: PreviewBuildPlatform
    init(platform: String) { self.platform = PreviewBuildPlatform(identifier: platform) }
}

private final class PreviewBuildPlatform: NSObject {
    @objc let identifier: String
    @objc let userDescription = "Preview platform"
    init(identifier: String) { self.identifier = identifier }
}
