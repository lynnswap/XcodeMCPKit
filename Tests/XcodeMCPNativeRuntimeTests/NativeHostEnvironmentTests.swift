import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeHostEnvironmentTests {
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
