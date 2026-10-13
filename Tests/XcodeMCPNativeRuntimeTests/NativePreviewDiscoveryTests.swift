import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewDiscoveryTests {
    @Test func recognizesRegistryNamesWithMangledWordSubstitutions() {
        let symbol = "_$s15EmbeddedPreview04$s15a89Preview0024FrameworkViewswift_ynAHffMX12_0_33_11075570A56CB59BAD1AB26CEC639C6ELl0B0fMf_15B12RegistryfMu_VMn"
        let name = "15EmbeddedPreview04$s15a89Preview0024FrameworkViewswift_ynAHffMX12_0_33_11075570A56CB59BAD1AB26CEC639C6ELl0B0fMf_15B12RegistryfMu_V"
        #expect(NativePreviewCorrection.registryNames(in: symbol) == [name])
    }

    @Test func includesEmbeddedFrameworkExecutablesAndDebugLibraries() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let framework = app.appendingPathComponent("Frameworks/FixtureKit.framework", isDirectory: true)
        let nestedFrameworks = framework.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFrameworks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }

        let preview = app.appendingPathComponent("FixtureApp.debug.dylib")
        let rootDylib = app.appendingPathComponent("libRootPreview.dylib")
        let executable = framework.appendingPathComponent("FixtureImplementation")
        let frameworkPreview = framework.appendingPathComponent("FixtureImplementation.debug.dylib")
        let dylib = app.appendingPathComponent("Frameworks/LinkedPreview.dylib")
        let nestedDylib = nestedFrameworks.appendingPathComponent("NestedPreview.dylib")
        for library in [preview, rootDylib, executable, frameworkPreview, dylib, nestedDylib] {
            try Data().write(to: library)
        }
        let info = ["CFBundleExecutable": "FixtureImplementation", "CFBundlePackageType": "FMWK",
                    "CFBundleIdentifier": "dev.lynnswap.FixtureKit"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: framework.appendingPathComponent("Info.plist"))

        let libraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [preview])
        let expected = [preview, rootDylib, executable, frameworkPreview, dylib, nestedDylib]
            .map { $0.resolvingSymlinksInPath().path }
        #expect(Set(libraries.map(\.path)) == Set(expected))

        let frameworkPaths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [preview],
            registryLibraries: libraries, sourceOutput: app.deletingLastPathComponent()
                .appendingPathComponent("FixtureKit.framework/FixtureImplementation"))
        #expect(frameworkPaths == ["FixtureApp.debug.dylib", "Frameworks/FixtureKit.framework/FixtureImplementation"])

        let staticPaths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [preview],
            registryLibraries: libraries, sourceOutput: app.deletingLastPathComponent().appendingPathComponent("FixturePackage.o"))
        #expect(staticPaths == ["FixtureApp.debug.dylib"])
    }
}
