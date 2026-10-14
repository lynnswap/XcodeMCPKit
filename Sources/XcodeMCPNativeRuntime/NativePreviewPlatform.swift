import Foundation

enum NativePreviewPlatform: String, CaseIterable {
    case iOS = "iphonesimulator"
    case tvOS = "appletvsimulator"
    case visionOS = "xrsimulator"
    case watchOS = "watchsimulator"
    case macOS = "macosx"
    case catalyst = "maccatalyst"

    init?(sdkRoot: String, sdkVariant: String?) {
        if sdkRoot.contains("MacOSX") || sdkRoot.contains("macosx") {
            self = sdkVariant == "iosmac" ? .catalyst : .macOS
        } else if let platform = Self.allCases.first(where: { sdkRoot.lowercased().contains($0.rawValue) }) {
            self = platform
        } else { return nil }
    }

    init?(platformIdentifier: String?, isMacCatalyst: Bool) {
        switch platformIdentifier {
        case "com.apple.platform.iphonesimulator": self = .iOS
        case "com.apple.platform.appletvsimulator": self = .tvOS
        case "com.apple.platform.xrsimulator": self = .visionOS
        case "com.apple.platform.watchsimulator": self = .watchOS
        case "com.apple.platform.macosx": self = isMacCatalyst ? .catalyst : .macOS
        default: return nil
        }
    }

    var isSimulator: Bool { self != .macOS && self != .catalyst }
    var helperDirectory: String { rawValue + "-arm64" }
    var sdk: String { self == .catalyst ? "macosx" : rawValue }
    var minimumVersion: String {
        switch self {
        case .iOS, .tvOS: "18.4"
        case .visionOS: "2.4"
        case .watchOS: "11.4"
        case .macOS, .catalyst: "15.4"
        }
    }
    var triple: String {
        switch self {
        case .iOS: "arm64-apple-ios18.4-simulator"
        case .tvOS: "arm64-apple-tvos18.4-simulator"
        case .visionOS: "arm64-apple-xros2.4-simulator"
        case .watchOS: "arm64-apple-watchos11.4-simulator"
        case .macOS: "arm64-apple-macos15.4"
        case .catalyst: "arm64-apple-ios18.4-macabi"
        }
    }

    static func supportsDestination(platformIdentifier: String?, identifier: String) -> Bool {
        switch platformIdentifier {
        case "com.apple.platform.macosx": true
        case "com.apple.platform.iphonesimulator", "com.apple.platform.appletvsimulator",
             "com.apple.platform.xrsimulator", "com.apple.platform.watchsimulator":
            UUID(uuidString: identifier) != nil
        default: false
        }
    }

    func executableDirectory(in app: URL) -> URL { isSimulator ? app : app.appendingPathComponent("Contents/MacOS") }
    func resourcesDirectory(in app: URL) -> URL { isSimulator ? app : app.appendingPathComponent("Contents/Resources") }
    func frameworksDirectory(in app: URL) -> URL { app.appendingPathComponent(isSimulator ? "Frameworks" : "Contents/Frameworks") }
    func infoURL(in app: URL) -> URL { app.appendingPathComponent(isSimulator ? "Info.plist" : "Contents/Info.plist") }
}
