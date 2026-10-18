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

    @Test func compilationCacheDefaultsAreIndependentOfWorkspaceAndDerivedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: app)

        let first = installation.launchEnvironment(base: ["DERIVED_DATA_DIR": root.appendingPathComponent("First").path], sharesCompilationCache: true)
        let second = installation.launchEnvironment(base: ["DERIVED_DATA_DIR": root.appendingPathComponent("Second").path], sharesCompilationCache: true)

        let cachePath = try #require(first["CompilationCachingCASPath"])
        #expect(cachePath.hasPrefix("/"))
        #expect(second["CompilationCachingCASPath"] == cachePath)
        #expect(first["DERIVED_DATA_DIR"] != second["DERIVED_DATA_DIR"])
    }

    @MainActor @Test func compilationSettingsInheritProjectValuesAndPreserveExplicitDefaults() {
        let settings = NativeApplicationBootstrap.compilationCacheSettings(
            existing: ["SWIFT_ENABLE_PREFIX_MAPPING": "NO", "CUSTOM_SETTING": "preserved"],
            environment: ["CLANG_ENABLE_PREFIX_MAPPING": "NO", "SWIFT_ENABLE_BATCH_MODE": "YES"])

        #expect(settings["COMPILATION_CACHE_ENABLE_CACHING_DEFAULT"] as? String == "$(inherited:default=YES)")
        #expect(settings["SWIFT_ENABLE_PREFIX_MAPPING"] as? String == "NO")
        #expect(settings["SWIFT_ENABLE_PROJECT_PREFIX_MAPPING"] as? String
            == "$(inherited:default=$(XCODE_MCPKIT_PROJECT_PREFIX_FOR_BATCH_$(SWIFT_ENABLE_BATCH_MODE):default=YES))")
        #expect(settings["CLANG_ENABLE_PREFIX_MAPPING"] as? String == "$(inherited:default=NO)")
        #expect(settings["CLANG_ENABLE_PROJECT_PREFIX_MAPPING"] as? String == "$(inherited:default=YES)")
        #expect(settings["CUSTOM_SETTING"] as? String == "preserved")
        #expect(settings["SWIFT_ENABLE_BATCH_MODE"] as? String == "YES")
    }

    @Test func explicitCompilationCacheEnvironmentIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        let installation = try NativeXcodeInstallation(developerDirectory: app)
        let explicit = [
            "COMPILATION_CACHE_ENABLE_CACHING_DEFAULT": "NO",
            "CompilationCachingCASPath": "/Custom Cache/CompilationCache.noindex",
            "SWIFT_ENABLE_PREFIX_MAPPING": "NO",
            "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING": "NO",
            "CLANG_ENABLE_PREFIX_MAPPING": "NO",
            "CLANG_ENABLE_PROJECT_PREFIX_MAPPING": "NO",
            "PATH": "/usr/bin",
        ]

        let environment = installation.launchEnvironment(base: explicit, sharesCompilationCache: true)

        for (key, value) in explicit {
            #expect(environment[key] == value)
        }
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
        let environment = installation.launchEnvironment(base: [:])
        #expect(environment["DEVELOPER_DIR"] == contents.appendingPathComponent("Developer").path)
        #expect(environment["CompilationCachingCASPath"] == nil)
    }
}
