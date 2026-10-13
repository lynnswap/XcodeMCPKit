import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewCorrectionTests {
    @Test(arguments: [true, false])
    func sharedSourceUsesRunnableHost(sharedLibrary: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("SharedView.swift")
        let library = root.appendingPathComponent("SharedPreview.o")
        let hosts = ["FirstApp", "RunnableApp"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path]
                    + (sharedLibrary ? [library.path] : []),
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: sharedLibrary ? [] : [source],
                debugDylibEnabled: true, isRunnable: name == "RunnableApp")
        }
        let targets = hosts + (sharedLibrary ? [NativePreviewBuild.Target(moduleName: "SharedPreview",
            buildableName: "SharedPreview.o", sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64",
            linkCommandLine: ["-o", library.path], linkerWorkingDirectory: nil, objectFiles: [],
            sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)] : [])
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source)
        #expect(selected.host.moduleName == "RunnableApp")
        #expect(selected.source.moduleName == (sharedLibrary ? "SharedPreview" : "RunnableApp"))
    }

    @Test func ambiguousHostsRequireNativePipeline() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("SharedView.swift")
        let targets = ["FirstApp", "SecondApp"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source],
                debugDylibEnabled: true, isRunnable: false)
        }
        #expect(throws: NativePipelineRequired.self) {
            try NativePreviewCorrection.selectTarget(targets, source: source)
        }
    }

    @Test(arguments: [true, false])
    func dylibSourceUsesLinkedOrEmbeddedAppHost(embedded: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FeaturePreview.swift")
        let dylib = root.appendingPathComponent("libFeature.dylib")
        let hosts = ["Unrelated", "Linked"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path]
                    + (!embedded && name == "Linked" ? [dylib.path] : []),
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: false)
        }
        let feature = NativePreviewBuild.Target(moduleName: "Feature", buildableName: "libFeature.dylib",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", dylib.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        if embedded {
            let binary = root.appendingPathComponent("Linked.app/Frameworks/libFeature.dylib")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: binary)
        }
        let selected = try NativePreviewCorrection.selectTarget(hosts + [feature], source: source)
        #expect(selected.host.outputURL == hosts[1].outputURL)
        #expect(selected.source.outputURL == feature.outputURL)
        #expect(selected.source.moduleName == feature.moduleName)
    }

    @Test(arguments: [true, false])
    func frameworkHostMustEmbedSourceFramework(embedded: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FrameworkView.swift")
        let frameworkBinary = root.appendingPathComponent("FixtureKit.framework/FixtureKit")
        let hosts = ["Unrelated", "Linked"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: false)
        }
        let framework = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", frameworkBinary.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        if embedded {
            let binary = root.appendingPathComponent("Linked.app/Frameworks/FixtureKit.framework/FixtureKit")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: binary)
            let selected = try NativePreviewCorrection.selectTarget(hosts + [framework], source: source)
            #expect(selected.host.outputURL == hosts[1].outputURL)
            #expect(selected.source.outputURL == framework.outputURL)
            #expect(selected.source.moduleName == framework.moduleName)
        } else {
            #expect(throws: NativePipelineRequired.self) {
                try NativePreviewCorrection.selectTarget(hosts + [framework], source: source)
            }
        }
    }

    @Test(arguments: [true, false])
    func staticSourceUsesLinkedAppHost(linksObjects: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("PackageView.swift")
        let object = root.appendingPathComponent("PackageView.o")
        let archive = root.appendingPathComponent("FixturePackage.a")
        let hosts = ["Unrelated", "Linked"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path]
                    + (!linksObjects && name == "Linked" ? [archive.path] : []),
                linkerWorkingDirectory: nil, objectFiles: linksObjects && name == "Linked" ? [object] : [],
                sourceFiles: [], debugDylibEnabled: true, isRunnable: false)
        }
        let package = NativePreviewBuild.Target(moduleName: "FixturePackage", buildableName: "FixturePackage.a",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64",
            linkCommandLine: ["-o", archive.path],
            linkerWorkingDirectory: nil, objectFiles: [object], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        let selected = try NativePreviewCorrection.selectTarget(hosts + [package], source: source)
        #expect(selected.host.outputURL == hosts[1].outputURL)
        #expect(selected.source.outputURL == package.outputURL)
        #expect(selected.source.moduleName == package.moduleName)
    }

    @Test func staticProductInLinkFileList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("OwnApp.o\nFixturePackage.o\n".utf8).write(to: root.appendingPathComponent("Host.LinkFileList"))
        let source = root.appendingPathComponent("PackageView.swift")
        let product = root.appendingPathComponent("FixturePackage.o")
        let hosts = ["Unrelated", "Linked"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path]
                    + (name == "Linked" ? ["-filelist", "Host.LinkFileList"] : []),
                linkerWorkingDirectory: root.path, objectFiles: [root.appendingPathComponent("OwnApp.o")],
                sourceFiles: [], debugDylibEnabled: true, isRunnable: false)
        }
        let package = NativePreviewBuild.Target(moduleName: "FixturePackage", buildableName: "FixturePackage.o",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", product.path],
            linkerWorkingDirectory: nil, objectFiles: [root.appendingPathComponent("PackageContent.o")],
            sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        let selected = try NativePreviewCorrection.selectTarget(hosts + [package], source: source)
        #expect(selected.host.outputURL == hosts[1].outputURL)
        #expect(selected.source.outputURL == package.outputURL)
        #expect(selected.source.moduleName == package.moduleName)
    }

    @Test(arguments: [false, true])
    func stagedAppCleanupPreservesArtifacts(fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("preview.png")
        let log = root.appendingPathComponent("process.log")
        try Data("snapshot".utf8).write(to: snapshot)
        try Data("diagnostic".utf8).write(to: log)
        var stagedApp: URL?
        do {
            let value = try await NativePreviewCorrection.withStagedApp(in: root) { app in
                stagedApp = app
                try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
                try Data("application".utf8).write(to: app.appendingPathComponent("Executable"))
                if fails { throw NativePipelineRequired() }
                return "rendered"
            }
            #expect(!fails)
            #expect(value == "rendered")
        } catch {
            #expect(fails)
            #expect(error is NativePipelineRequired)
        }
        let app = try #require(stagedApp)
        #expect(!FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: snapshot) == Data("snapshot".utf8))
        #expect(try Data(contentsOf: log) == Data("diagnostic".utf8))
    }

    @Test func frameworkWithoutAppHostRequiresNativePipeline() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("FixtureView.swift")
        let target = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64",
            linkCommandLine: ["-o", root.appendingPathComponent("FixtureKit.framework/FixtureKit").path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)

        #expect(throws: NativePipelineRequired.self) {
            try NativePreviewCorrection.selectTarget([target], source: source)
        }
    }

    @Test func timeoutPreservesCleanupFailure() async {
        let identifier = UUID().uuidString
        do {
            try await NativePreviewCorrection.withTimeout(seconds: 0) {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    throw NativeRuntimeError.invocation("failed to delete preview Simulator \(identifier): cleanup failed")
                }
            }
            Issue.record("Expected a rendering timeout")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("Preview rendering exceeded 0 seconds"))
            #expect(description.contains("cleanup failed"))
            #expect(description.contains(identifier))
        }
    }

    @Test func unavailableInputContractPreservesNativeEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let correction = NativePreviewCorrection(installation: try NativeXcodeInstallation(developerDirectory: app))
        let input = try JSONEncoder().encode(PreviewInput(temporaryArtifactsPath: root.path, sourceFilePath: "ContentView.swift"))
        let nativeEvent = Data(#"{"type":"completed","data":{"native":true}}"#.utf8)
        let stream = try await correction.execute(inputType: PreviewInput.self, input: input) {
            AsyncStream { continuation in
                continuation.yield(nativeEvent)
                continuation.finish()
            }
        }
        var events: [Data] = []
        for await event in stream { events.append(event) }
        #expect(events == [nativeEvent])
    }
}

private struct PreviewInput: Codable {
    let temporaryArtifactsPath: String
    let sourceFilePath: String
}
