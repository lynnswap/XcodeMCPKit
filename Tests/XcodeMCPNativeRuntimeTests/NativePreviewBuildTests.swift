import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewBuildTests {
    @Test func respectsActiveDestinationAcrossPlatforms() throws {
        let mac = PreviewBuildDestination(identifier: "Mac", platform: "com.apple.platform.macosx")
        let ios = PreviewBuildDestination(identifier: UUID().uuidString, platform: "com.apple.platform.iphonesimulator")
        let candidates = [destination(mac, platformName: "macOS", previewIdentifier: "dvtdevice-local-computer:localhost"),
                          destination(ios, platformName: "iOS")]
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: mac, preferred: [:])?.value === mac)
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: mac,
            preferred: ["identifier": "dvtdevice-local-computer:localhost"])?.value === mac)
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: mac,
            preferred: ["identifier": ios.targetDevice.identifier])?.value === ios)
    }

    @Test(arguments: [["identifier": "dvtdevice-local-computer:localhost"], ["platformName": "Mac Catalyst"]])
    func retainsActiveSDKVariantWhenMacDestinationsShareADeviceIdentifier(preferred: [String: String]) throws {
        let identifier = "Mac"
        let mac = PreviewBuildDestination(identifier: identifier, platform: "com.apple.platform.macosx")
        let catalyst = PreviewBuildDestination(identifier: identifier, platform: "com.apple.platform.macosx", variant: "iosmac")
        let active = PreviewBuildDestination(identifier: identifier, platform: "com.apple.platform.macosx", variant: "iosmac")
        let candidates = [destination(mac, platformName: "macOS", previewIdentifier: "dvtdevice-local-computer:localhost"),
                          destination(catalyst, platformName: "Mac Catalyst", previewIdentifier: "dvtdevice-local-computer:localhost")]

        #expect(active !== catalyst)
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: active, preferred: preferred)?.value === catalyst)
    }

    @Test func selectsTheFirstNativeRecipeWithoutReorderingItsVersion() {
        let first = PreviewBuildDestination(identifier: UUID().uuidString, platform: "com.apple.platform.iphonesimulator")
        let last = PreviewBuildDestination(identifier: UUID().uuidString, platform: "com.apple.platform.iphonesimulator")
        let candidates = [destination(first, platformName: "iOS", version: "26.6"), destination(last, platformName: "iOS", version: "27.2")]
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: nil,
            preferred: ["platformName": "iOS"])?.value === first)
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: first,
            preferred: ["platformName": "iOS", "systemVersion": "27.2"])?.value === last)
        #expect(NativePreviewBuild.selectDestination(candidates: candidates, active: first,
            preferred: ["platformName": "macOS"]) == nil)
    }

    private func destination(_ value: PreviewBuildDestination, platformName: String, previewIdentifier: String? = nil,
                             version: String = "27.1") -> NativePreviewBuild.Destination {
        .init(value: value, identifier: value.targetDevice.identifier, previewIdentifier: previewIdentifier ?? value.targetDevice.identifier,
              platformIdentifier: value.targetSDK.platform.identifier,
              previewPlatform: NativePreviewPlatform(platformIdentifier: value.targetSDK.platform.identifier, isMacCatalyst: value.isMacCatalyst),
              platformName: platformName,
              deviceModelName: "Preview device", systemVersion: version)
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
    let variant: String?
    @objc var isMacCatalyst: Bool { variant == "iosmac" }
    init(identifier: String, platform: String, variant: String? = nil) {
        targetDevice = PreviewBuildDevice(identifier: identifier)
        targetSDK = PreviewBuildSDK(platform: platform)
        self.variant = variant
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PreviewBuildDestination else { return false }
        return targetDevice.identifier == other.targetDevice.identifier
            && targetSDK.platform.identifier == other.targetSDK.platform.identifier && variant == other.variant
    }
    override var hash: Int { targetDevice.identifier.hashValue ^ targetSDK.platform.identifier.hashValue ^ (variant?.hashValue ?? 0) }
}

private final class PreviewBuildDevice: NSObject {
    @objc let identifier: String
    @objc var deviceLocation: NSURL?
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
