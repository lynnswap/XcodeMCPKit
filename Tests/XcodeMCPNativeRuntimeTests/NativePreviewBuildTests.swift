import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewBuildTests {
    @Test func respectsActiveDestinationAcrossPlatforms() throws {
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

        #expect(try builder.selectDestination(workspace: workspace) === mac)
        #expect(try builder.selectDestination(workspace: workspace, preferred: ["identifier": ios.targetDevice.identifier]) === ios)
    }

    @Test func resolvesRunnableAndUsesNativeBuildableEquality() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = NativePreviewBuild(installation: try NativeXcodeInstallation(developerDirectory: app))
        let product = PreviewBuildBuildable(identity: "Selected")
        let equivalent = PreviewBuildBuildable(identity: "Selected")
        let unrelated = PreviewBuildBuildable(identity: "Unrelated")
        let scheme = PreviewBuildScheme(destinations: [], runnable: PreviewBuildRunnable(product: product))
        let resolved = try builder.runnableBuildable(in: scheme)
        let runnable = try #require(resolved)

        #expect(equivalent !== product)
        #expect(NativePreviewBuild.isRunnable(equivalent, runnable: runnable))
        #expect(!NativePreviewBuild.isRunnable(unrelated, runnable: runnable))

        let pathScheme = PreviewBuildScheme(destinations: [], runnable: PreviewBuildRunnable(product: nil))
        let absent = try builder.runnableBuildable(in: pathScheme)
        #expect(absent == nil)
        #expect(!NativePreviewBuild.isRunnable(equivalent, runnable: absent))
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
    @objc let launchSchemeAction: PreviewBuildLaunchAction
    init(destinations: [PreviewBuildDestination], runnable: PreviewBuildRunnable? = nil) {
        availableRunDestinations = NSArray(array: destinations)
        launchSchemeAction = PreviewBuildLaunchAction(runnable: runnable)
    }
}

private final class PreviewBuildLaunchAction: NSObject {
    @objc let runnable: PreviewBuildRunnable?
    init(runnable: PreviewBuildRunnable?) { self.runnable = runnable }
}

private final class PreviewBuildRunnable: NSObject {
    @objc let buildableProduct: PreviewBuildBuildable?
    init(product: PreviewBuildBuildable?) { buildableProduct = product }
}

private final class PreviewBuildBuildable: NSObject {
    let identity: String
    init(identity: String) { self.identity = identity }
    override func isEqual(_ object: Any?) -> Bool {
        (object as? PreviewBuildBuildable)?.identity == identity
    }
    override var hash: Int { identity.hashValue }
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
