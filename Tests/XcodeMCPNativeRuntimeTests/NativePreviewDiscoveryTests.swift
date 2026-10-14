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

    @Test func discoversProgramRootsFromCompilerMainSymbols() {
        let widgetRoot = "28OriginalWidgetProbeExtension0abC6BundleV"
        let appRoot = "10FixtureApp0B0V"
        let symbols = [
            "_$s\(widgetRoot)5$mainyyFZ",
            "_$s\(appRoot)5$mainyyFZ",
            "_$s\(widgetRoot)5$mainyyFZ",
            "_$s\(widgetRoot)4bodyQrvg",
            "_$s\(widgetRoot)VMn",
            "_main",
        ].joined(separator: "\n")
        #expect(NativePreviewCorrection.programRootNames(in: symbols) == [appRoot, widgetRoot])
        #expect(NativePreviewCorrection.programRootNames(in: "_$s\(widgetRoot)VMn") == [])
    }

    @Test func programLibrariesMatchTheBuiltHostImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appendingPathComponent("Built/Original.debug.dylib")
        let otherOutput = root.appendingPathComponent("Built/Other.debug.dylib")
        try compilePreviewLibrary(at: output)
        try compilePreviewLibrary(at: otherOutput, value: 1)
        let stagedHost = app.appendingPathComponent("RenamedHost.debug.dylib")
        let otherLibrary = app.appendingPathComponent("Original.debug.dylib")
        try FileManager.default.copyItem(at: output, to: stagedHost)
        try FileManager.default.copyItem(at: otherOutput, to: otherLibrary)

        #expect(try NativePreviewCorrection.programLibraries(previewLibraries: [otherLibrary, stagedHost], output: output) == [stagedHost])
        #expect(try NativePreviewCorrection.programLibraries(previewLibraries: [otherLibrary], output: output) == [])
    }

    @Test func includesEmbeddedFrameworkExecutablesAndDebugLibraries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let framework = app.appendingPathComponent("Frameworks/FixtureKit.framework", isDirectory: true)
        let wrongFramework = app.appendingPathComponent("Frameworks/AWrapper.framework/Frameworks/FixtureKit.framework", isDirectory: true)
        let nestedFrameworks = framework.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFrameworks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let preview = app.appendingPathComponent("FixtureApp.debug.dylib")
        let rootDylib = app.appendingPathComponent("libRootPreview.dylib")
        let executable = framework.appendingPathComponent("FixtureImplementation")
        let frameworkPreview = framework.appendingPathComponent("FixtureImplementation.debug.dylib")
        let dylib = app.appendingPathComponent("Frameworks/LinkedPreview.dylib")
        let nestedDylib = nestedFrameworks.appendingPathComponent("NestedPreview.dylib")
        let sourceOutput = root.appendingPathComponent("Built/FixtureKit.framework/FixtureImplementation")
        let wrongExecutable = wrongFramework.appendingPathComponent("FixtureImplementation")
        try compilePreviewLibrary(at: sourceOutput)
        try compilePreviewLibrary(at: wrongExecutable, value: 1)
        for library in [preview, rootDylib, executable, frameworkPreview, dylib, nestedDylib] {
            try FileManager.default.copyItem(at: sourceOutput, to: library)
        }
        let info = ["CFBundleExecutable": "FixtureImplementation", "CFBundlePackageType": "FMWK",
                    "CFBundleIdentifier": "dev.lynnswap.FixtureKit"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: framework.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: wrongFramework.appendingPathComponent("Info.plist"))

        let libraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [preview])
        let expected = [preview, rootDylib, executable, frameworkPreview, dylib, nestedDylib, wrongExecutable]
            .map { $0.resolvingSymlinksInPath().path }
        #expect(Set(libraries.map(\.path)) == Set(expected))

        let frameworkPaths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [preview],
            registryLibraries: libraries, sourceOutput: sourceOutput)
        #expect(frameworkPaths == ["FixtureApp.debug.dylib", "Frameworks/FixtureKit.framework/FixtureImplementation"])

        let staticPaths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [preview],
            registryLibraries: libraries, sourceOutput: app.deletingLastPathComponent().appendingPathComponent("FixturePackage.o"))
        #expect(staticPaths == ["FixtureApp.debug.dylib"])
    }
}
