import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeHostEnvironmentTests {
    @Test func originDescribesTheSelectedInstallationAndActualProviderProcess() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("SelectedXcode.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/IDEFoundation.framework"), withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "test.selected.Xcode", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "test-version"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let installation = try NativeXcodeInstallation(developerDirectory: app)
        let origin = installation.origin(kind: "gui", processID: 731, toolCancellation: "waitForNativeCompletion")
        #expect(origin["kind"] == .string("gui"))
        #expect(origin["processID"] == .number(.int(731)))
        #expect(origin["hostPID"] == .number(.int(Int64(getpid()))))
        #expect(origin["appPath"] == .string(app.path))
        #expect(origin["developerDirectory"] == .string(contents.appendingPathComponent("Developer").path))
        #expect(origin["xcodeVersion"] == .string("test-version"))
        #expect(origin["toolCancellation"] == .string("waitForNativeCompletion"))
    }

    @Test(arguments: ["Xcode.app", "Xcode.app/Contents/Developer"])
    func applicationAndDeveloperPathsSelectTheSameInstallation(relativePath: String) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Xcode.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/IDEFoundation.framework"), withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: root.appendingPathComponent(relativePath))
        #expect(installation.contentsDirectory.path == contents.path)
        #expect(installation.developerDirectory.path == contents.appendingPathComponent("Developer").path)
        #expect(installation.launchEnvironment(base: [:])["DEVELOPER_DIR"] == contents.appendingPathComponent("Developer").path)
    }
}
