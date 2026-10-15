import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewCorrectionTests {
    @Test(arguments: [NativePreviewPlatform.iOS, .catalyst])
    func sharedSourceUsesTheSelectedDestinationPlatform(platform: NativePreviewPlatform) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("SharedView.swift")
        let targets = [NativePreviewPlatform.watchOS, .macOS, .iOS, .catalyst].map { candidate -> NativePreviewBuild.Target in
            let output = root.appendingPathComponent("\(candidate.rawValue).app/Preview.debug.dylib")
            let sdkVariant: String? = candidate == .catalyst ? "iosmac" : nil
            let isRunnable = candidate == .watchOS || candidate == .macOS
            return NativePreviewBuild.Target(moduleName: candidate.rawValue, buildableName: "\(candidate.rawValue).app",
                sdkRoot: candidate.sdk, sdkVariant: sdkVariant, architecture: "arm64",
                linkCommandLine: ["-o", output.path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: true,
                isRunnable: isRunnable)
        }
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: platform)
        #expect(selected.source.moduleName == platform.rawValue)
        #expect(selected.host.moduleName == platform.rawValue)
    }

    @Test func watchOnlySourceRequiresNativePipelineForAnIPhoneDestination() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("WatchView.swift")
        let watch = NativePreviewBuild.Target(moduleName: "Watch", buildableName: "Watch.app", sdkRoot: "watchsimulator",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", root.appendingPathComponent("Watch.app/Watch.debug.dylib").path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: true, isRunnable: true)
        #expect(throws: NativePipelineRequired.self) {
            try NativePreviewCorrection.selectTarget([watch], source: source, platform: .iOS)
        }
    }

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
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .iOS)
        #expect(selected.host.moduleName == "RunnableApp")
        #expect(selected.source.moduleName == (sharedLibrary ? "SharedPreview" : "RunnableApp"))
    }

    @Test func stagesMacProductInItsContentsLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let product = root.appendingPathComponent("Original.app")
        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        for directory in [product.appendingPathComponent("Contents/MacOS"), product.appendingPathComponent("Contents/Resources"),
                          product.appendingPathComponent("Contents/Frameworks"), helper.appendingPathComponent("Frameworks")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let original: [String: Any] = ["CFBundleIdentifier": "dev.lynnswap.MacFixture", "CFBundleExecutable": "Original",
            "CFBundlePackageType": "APPL", "NSMainStoryboardFile": "Original", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
            .write(to: product.appendingPathComponent("Contents/Info.plist"))
        try Data("original".utf8).write(to: product.appendingPathComponent("Contents/MacOS/Original"))
        try Data("resource".utf8).write(to: product.appendingPathComponent("Contents/Resources/Marker.txt"))
        try Data("renderer".utf8).write(to: helper.appendingPathComponent("XcodeMCPPreviewRenderer"))
        try Data("library".utf8).write(to: helper.appendingPathComponent("Frameworks/libPreview.dylib"))
        try NativePreviewCorrection.prepareApp(product: product, helper: helper, app: app, platform: .macOS)
        let info = try #require(Bundle(url: app)?.infoDictionary)
        #expect(info["CFBundleIdentifier"] as? String == "dev.lynnswap.MacFixture")
        #expect(info["NSMainStoryboardFile"] == nil)
        #expect(info["UIApplicationSceneManifest"] == nil)
        #expect(info["LSMinimumSystemVersion"] as? String == "15.4")
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/XcodeMCPPreviewRenderer")) == Data("renderer".utf8))
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/Frameworks/libPreview.dylib")) == Data("library".utf8))
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/Marker.txt")) == Data("resource".utf8))
    }

    @Test func watchRendererRunsWithoutACompanionApp() {
        let original: [String: Any] = ["CFBundleIdentifier": "dev.lynnswap.WatchFixture",
            "WKCompanionAppBundleIdentifier": "dev.lynnswap.Companion", "WKRunsIndependentlyOfCompanionApp": true]
        let info = NativePreviewCorrection.rendererInfo(original, platform: .watchOS)
        #expect(info["WKApplication"] as? Bool == true)
        #expect(info["WKWatchOnly"] as? Bool == true)
        #expect(info["WKCompanionAppBundleIdentifier"] == nil)
        #expect(info["WKRunsIndependentlyOfCompanionApp"] == nil)
        #expect(info["CFBundleIdentifier"] as? String == "dev.lynnswap.WatchFixture")
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
            try NativePreviewCorrection.selectTarget(targets, source: source, platform: .iOS)
        }
    }

    @Test func sharedLibraryVariantsUseSupportedArchitecture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("PackageView.swift")
        let product = root.appendingPathComponent("FixturePackage.o")
        let targets = ["arm64", "x86_64"].flatMap { architecture in
            [NativePreviewBuild.Target(moduleName: "FixturePackage", buildableName: "FixturePackage.o",
                sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: architecture,
                linkCommandLine: ["-o", product.path], linkerWorkingDirectory: nil, objectFiles: [],
                sourceFiles: [source], debugDylibEnabled: false, isRunnable: false),
             NativePreviewBuild.Target(moduleName: "FixtureHost", buildableName: "FixtureHost.app",
                sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: architecture,
                linkCommandLine: ["-o", root.appendingPathComponent("FixtureHost.app/FixtureHost.debug.dylib").path, product.path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: true)]
        }
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .iOS)
        #expect(selected.source.architecture == "arm64")
        #expect(selected.host.architecture == "arm64")
        #expect(throws: NativePipelineRequired.self) {
            try NativePreviewCorrection.selectTarget(targets.filter { $0.architecture == "x86_64" }, source: source, platform: .iOS)
        }
    }

    @Test(arguments: [true, false])
    func dylibSourceUsesLinkedOrEmbeddedAppHost(embedded: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FeaturePreview.swift")
        let dylib = root.appendingPathComponent("libFeature.dylib")
        try compilePreviewLibrary(at: dylib)
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
            try FileManager.default.copyItem(at: dylib, to: binary)
        }
        let selected = try NativePreviewCorrection.selectTarget(hosts + [feature], source: source, platform: .iOS)
        #expect(selected.host.outputURL == hosts[1].outputURL)
        #expect(selected.source.outputURL == feature.outputURL)
        #expect(selected.source.moduleName == feature.moduleName)
    }

    @Test(arguments: [true, false])
    func frameworkHostPrefersOnlyMatchingEmbeddedBinary(embedded: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FrameworkView.swift")
        let frameworkBinary = root.appendingPathComponent("FixtureKit.framework/FixtureKit")
        try compilePreviewLibrary(at: frameworkBinary)
        try compilePreviewLibrary(at: root.appendingPathComponent("Unrelated.app/Frameworks/FixtureKit.framework/FixtureKit"), value: 1)
        let hosts = ["Unrelated", "Linked"].map { (name: String) in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: name == "Unrelated")
        }
        let framework = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", frameworkBinary.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        if embedded {
            let binary = root.appendingPathComponent("Linked.app/Frameworks/FixtureKit.framework/FixtureKit")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: frameworkBinary, to: binary)
        }
        let selected = try NativePreviewCorrection.selectTarget(hosts + [framework], source: source, platform: .iOS)
        #expect(selected.host.outputURL == (embedded ? hosts[1].outputURL : framework.outputURL))
        #expect(selected.source.outputURL == framework.outputURL)
        #expect(selected.source.moduleName == framework.moduleName)
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
        let selected = try NativePreviewCorrection.selectTarget(hosts + [package], source: source, platform: .iOS)
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
        let selected = try NativePreviewCorrection.selectTarget(hosts + [package], source: source, platform: .iOS)
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

    @Test(arguments: [NativePreviewPlatform.iOS, .macOS], [false, true])
    func frameworkUsesAnEmbeddedAppOrItsOwnProduct(platform: NativePreviewPlatform, embedded: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FrameworkView.swift")
        let binary = root.appendingPathComponent("FixtureKit.framework/FixtureKit")
        try compilePreviewLibrary(at: binary, platform: platform)
        let framework = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: platform.rawValue, sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", binary.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        var targets = [framework]
        if embedded {
            let app = root.appendingPathComponent("Host.app")
            let copy = platform.frameworksDirectory(in: app).appendingPathComponent("FixtureKit.framework/FixtureKit")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: binary, to: copy)
            targets.append(NativePreviewBuild.Target(moduleName: "Host", buildableName: "Host.app", sdkRoot: platform.rawValue,
                sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", platform.executableDirectory(in: app).appendingPathComponent("Host.debug.dylib").path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: true))
        }
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: platform)
        #expect(selected.source.moduleName == "FixtureKit")
        #expect(selected.host.moduleName == (embedded ? "Host" : "FixtureKit"))
    }

    @Test func linkedDynamicFrameworkWithoutEmbeddingUsesItsOwnProduct() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FrameworkView.swift")
        let binary = root.appendingPathComponent("FixtureKit.framework/FixtureKit")
        try compilePreviewLibrary(at: binary, platform: .macOS)
        let framework = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", binary.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        let appImage = root.appendingPathComponent("Host.app/Contents/MacOS/Host.debug.dylib")
        let app = NativePreviewBuild.Target(moduleName: "Host", buildableName: "Host.app", sdkRoot: "macosx",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: [binary.path, "-o", appImage.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: true)
        let selected = try NativePreviewCorrection.selectTarget([framework, app], source: source, platform: .macOS)
        #expect(selected.source.moduleName == "FixtureKit")
        #expect(selected.host.moduleName == "FixtureKit")
    }

    @Test(arguments: [false, true])
    func staticFrameworkUsesItsOwnProductOrItsLinkedApp(forceLoad: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FrameworkPreview.swift")
        let coreSource = root.appendingPathComponent("FrameworkCore.swift")
        let binary = root.appendingPathComponent("FixtureKit.framework/FixtureKit")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object = root.appendingPathComponent("FrameworkPreview.o")
        let core = root.appendingPathComponent("FrameworkCore.o")
        try Data("@_cdecl(\"static_core_value\") public func coreValue() -> Int32 { 7 }".utf8).write(to: coreSource)
        try Data("""
        import SwiftUI
        @_cdecl("static_preview_value") public func previewValue() -> Int32 { 22 }
        #Preview { Text("Unreferenced preview member") }
        """.utf8).write(to: source)
        let compileCommand = ["swiftc", "-parse-as-library", "-c", "-module-name", "FixtureKit", "-target",
            NativePreviewPlatform.macOS.triple, source.path, "-o", object.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + compileCommand)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-parse-as-library", "-c",
            "-module-name", "FixtureKit", "-target", NativePreviewPlatform.macOS.triple, coreSource.path, "-o", core.path])
        let archiveCommand = ["libtool", "-static", core.path, object.path, "-o", binary.path]
        try previewBinaryOutput("/usr/bin/xcrun", archiveCommand)
        let target = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: archiveCommand,
            linkerWorkingDirectory: nil, objectFiles: [core, object], sourceFiles: [source, coreSource], debugDylibEnabled: false,
            isRunnable: false, compileCommandLine: compileCommand)
        let standalone = try NativePreviewCorrection.selectTarget([target], source: source, platform: .macOS)
        #expect(standalone.host.moduleName == "FixtureKit")
        let appURL = root.appendingPathComponent("Host.app")
        let appImage = appURL.appendingPathComponent("Contents/MacOS/Host.debug.dylib")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: appImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lynnswap.StaticHost",
            "CFBundleExecutable": "Host", "CFBundleName": "Host", "CFBundlePackageType": "APPL"], format: .binary, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try Data("host resource".utf8).write(to: resources.appendingPathComponent("Marker.txt"))
        let appCode = root.appendingPathComponent("Host.swift")
        try Data("""
        @_silgen_name("static_core_value") func coreValue() -> Int32
        @_cdecl("app_host_value") public func hostValue() -> Int32 { coreValue() }
        """.utf8).write(to: appCode)
        var appCommand = ["--sdk", "macosx", "swiftc", "-parse-as-library", "-emit-library", "-target", NativePreviewPlatform.macOS.triple,
            appCode.path, "-F", root.path, "-framework", "FixtureKit", "-o", appImage.path]
        if forceLoad { appCommand += ["-Xlinker", "-force_load", "-Xlinker", binary.path] }
        try previewBinaryOutput("/usr/bin/xcrun", appCommand)
        let appSymbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", appImage.path])
        #expect(!NativePreviewCorrection.registryNames(in: appSymbols).isEmpty == forceLoad)
        let app = NativePreviewBuild.Target(moduleName: "Host", buildableName: "Host.app", sdkRoot: "macosx",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: appCommand,
            linkerWorkingDirectory: root.path, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: true)
        let hosted = try NativePreviewCorrection.selectTarget([target, app], source: source, platform: .macOS)
        #expect(hosted.host.moduleName == "Host")
        #expect(hosted.source.moduleName == "FixtureKit")
        let helper = root.appendingPathComponent("Helper")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loader = root.appendingPathComponent("Loader.m")
        try Data("""
        #import <Foundation/Foundation.h>
        #include <dlfcn.h>
        int main(int argc, char **argv) {
            @autoreleasepool {
                void *image = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
                if (!image) { fputs(dlerror(), stderr); return 1; }
                int (*value)(void) = dlsym(image, "static_preview_value");
                if (!value || dlsym(RTLD_DEFAULT, "app_host_value")) return 2;
                puts(NSBundle.mainBundle.bundleIdentifier.UTF8String);
                puts([[NSString alloc] initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"Marker" withExtension:@"txt"]
                    encoding:NSUTF8StringEncoding error:nil].UTF8String);
                printf("%d\\n", value());
            }
        }
        """.utf8).write(to: loader)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-framework", "Foundation", loader.path,
            "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        let staged = root.appendingPathComponent("Preview.app")
        try NativePreviewCorrection.prepareApp(product: appURL, helper: helper, app: staged, platform: .macOS)
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let linked = try await NativePreviewCorrection.linkStaticFramework(hosted.source, in: staged, platform: .macOS, process: process)
        let libraries = try NativePreviewCorrection.registryLibraries(in: staged, previewLibraries: [linked.url])
        let paths = try NativePreviewCorrection.libraryPaths(in: staged, previewLibraries: [linked.url], registryLibraries: libraries,
            sourceOutput: linked.url)
        #expect(paths == ["Contents/Frameworks/XcodeMCPPreviewSource.dylib"])
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", linked.url.path])
        #expect(!NativePreviewCorrection.registryNames(in: symbols).isEmpty)
        let executable = staged.appendingPathComponent("Contents/MacOS/XcodeMCPPreviewRenderer")
        #expect(try await process.run(executable.path, [linked.url.path]) == "dev.lynnswap.StaticHost\nhost resource\n22\n")
        #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Frameworks/FixtureKit.framework").path))
    }

    @Test func staticFrameworkSidecarRetainsCodeAndStagesItsDynamicDependency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("FixtureKit.framework")
        let binary = framework.appendingPathComponent("FixtureKit")
        let resources = framework.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lynnswap.StaticFixtureKit",
            "CFBundleExecutable": "FixtureKit", "CFBundlePackageType": "FMWK"], format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("Info.plist"))
        try Data("static resource".utf8).write(to: resources.appendingPathComponent("Marker.txt"))
        let support = root.appendingPathComponent("Vendor/libSupport.dylib")
        try compilePreviewLibrary(at: support, value: 21, platform: .macOS, installName: "@rpath/libSupport.dylib")
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", support.path])
        let frameworkSearchPath = root.appendingPathComponent("FrameworkVendor")
        let dependency = frameworkSearchPath.appendingPathComponent("Dependency.framework")
        let dependencyBinary = dependency.appendingPathComponent("Dependency")
        let dependencyModule = dependency.appendingPathComponent("Modules/Dependency.swiftmodule")
        try FileManager.default.createDirectory(at: dependencyModule, withIntermediateDirectories: true)
        let dependencyResources = dependency.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: dependencyResources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lynnswap.Dependency",
            "CFBundleExecutable": "Dependency", "CFBundlePackageType": "FMWK"], format: .binary, options: 0)
            .write(to: dependencyResources.appendingPathComponent("Info.plist"))
        let dependencyCode = root.appendingPathComponent("Dependency.swift")
        try Data("public func dependencyValue() -> Int32 { 10 }".utf8).write(to: dependencyCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-emit-library", "-emit-module",
            "-module-name", "Dependency", "-target", NativePreviewPlatform.macOS.triple, dependencyCode.path,
            "-emit-module-path", dependencyModule.appendingPathComponent("arm64-apple-macos.swiftmodule").path,
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/Dependency.framework/Dependency", "-o", dependencyBinary.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", dependency.path])
        let staticCode = root.appendingPathComponent("StaticDependency.cpp")
        let staticObject = root.appendingPathComponent("StaticDependency.o")
        let staticFramework = frameworkSearchPath.appendingPathComponent("StaticDependency.framework")
        let staticModule = staticFramework.appendingPathComponent("Modules/StaticDependency.swiftmodule")
        try FileManager.default.createDirectory(at: staticModule, withIntermediateDirectories: true)
        let staticArchive = staticFramework.appendingPathComponent("StaticDependency")
        try Data("""
        #include <string>
        extern "C" int archive_dependency_value(void) { return (int)std::string("x").size(); }
        """.utf8).write(to: staticCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang++", "-target", NativePreviewPlatform.macOS.triple,
            "-fsanitize=address", "-c", staticCode.path, "-o", staticObject.path])
        let staticSwiftCode = root.appendingPathComponent("StaticDependency.swift")
        let staticSwiftObject = root.appendingPathComponent("StaticDependencySwift.o")
        try Data("""
        @_silgen_name("archive_dependency_value") func archiveValue() -> Int32
        public func staticDependencyValue() -> Int32 { archiveValue() }
        """.utf8).write(to: staticSwiftCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-parse-as-library", "-c", "-emit-module",
            "-module-name", "StaticDependency", "-target", NativePreviewPlatform.macOS.triple, staticSwiftCode.path,
            "-emit-module-path", staticModule.appendingPathComponent("arm64-apple-macos.swiftmodule").path,
            "-o", staticSwiftObject.path])
        try previewBinaryOutput("/usr/bin/xcrun", ["libtool", "-static", staticObject.path, staticSwiftObject.path,
            "-o", staticArchive.path])
        let code = root.appendingPathComponent("StaticSource.c")
        let object = root.appendingPathComponent("StaticSource.o")
        // Model the compiler autolink directives that survive in a static archive until its final image is linked.
        try Data("""
        __asm__(".linker_option \\\"-lSupport\\\"");
        int main(void) { return 91; }
        """.utf8).write(to: code)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-target", NativePreviewPlatform.macOS.triple,
            "-c", code.path, "-o", object.path])
        let swiftCode = root.appendingPathComponent("StaticSource.swift")
        let swiftObject = root.appendingPathComponent("StaticSwiftSource.o")
        try Data("""
        import Dependency
        import StaticDependency
        @_silgen_name("preview_fixture_value") func supportValue() -> Int32
        @_cdecl("static_preview_value") public func staticPreviewValue() -> Int32 {
            dependencyValue() + supportValue() + staticDependencyValue()
        }
        """.utf8).write(to: swiftCode)
        let compileCommand = ["swiftc", "-parse-as-library", "-c", "-target", NativePreviewPlatform.macOS.triple,
            "-F", frameworkSearchPath.path, swiftCode.path, "-o", swiftObject.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + compileCommand)
        // Xcode's archive command keeps its Products -L but has no framework link step or -F.
        let command = ["libtool", "-static", "-L" + root.path, "-L" + support.deletingLastPathComponent().path,
            object.path, swiftObject.path, staticArchive.path,
            "-o", binary.path]
        try previewBinaryOutput("/usr/bin/xcrun", command)
        let target = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: command,
            linkerWorkingDirectory: root.path, objectFiles: [object], sourceFiles: [code], debugDylibEnabled: false, isRunnable: false,
            compileCommandLine: compileCommand, enableAddressSanitizer: true)
        let original = try Data(contentsOf: binary)
        let originalSupport = try Data(contentsOf: support)
        let originalDependency = try Data(contentsOf: dependencyBinary)
        let originalStaticDependency = try Data(contentsOf: staticArchive)
        let helper = root.appendingPathComponent("Helper")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loader = root.appendingPathComponent("Loader.c")
        try Data("""
        #include <dlfcn.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        int main(int argc, char **argv) {
            if (!dlsym(RTLD_DEFAULT, "__asan_init") || !getenv("ASAN_OPTIONS") ||
                strcmp(getenv("ASAN_OPTIONS"), "color=never:external_symbolizer_path='':abort_on_error=1")) return 2;
            void *image = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
            if (!image) { fputs(dlerror(), stderr); return 1; }
            int (*value)(void) = dlsym(image, "static_preview_value");
            if (!value) { fputs(dlerror(), stderr); return 1; }
            printf("%d\\n", value()); return 0;
        }
        """.utf8).write(to: loader)
        let executable = helper.appendingPathComponent("XcodeMCPPreviewRenderer")
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", loader.path, "-o", executable.path])
        let helperBytes = try Data(contentsOf: executable)
        let app = root.appendingPathComponent("Preview.app")
        try NativePreviewCorrection.prepareApp(product: framework, helper: helper, app: app, platform: .macOS)
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let linked = try await NativePreviewCorrection.linkStaticFramework(target, in: app, platform: .macOS, process: process)
        let image = linked.url
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: target, targets: [target], platform: .macOS,
            primaryImage: linked)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: app, platform: .macOS)
        let libraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [image])
        let paths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [image], registryLibraries: libraries,
            sourceOutput: image)
        #expect(paths == ["Contents/Frameworks/XcodeMCPPreviewSource.dylib"])
        #expect(try NativePreviewCorrection.programLibraries(previewLibraries: libraries, output: image) == [image.resolvingSymlinksInPath()])
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", image.path]).split(whereSeparator: \.isNewline)
        #expect(symbols.contains("_static_preview_value"))
        #expect(symbols.contains("_main"))
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies, in: app, platform: .macOS, process: process)
        let stagedExecutable = NativePreviewPlatform.macOS.executableDirectory(in: app).appendingPathComponent(executable.lastPathComponent)
        let runtime = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang",
            "-print-file-name=libclang_rt.asan_osx_dynamic.dylib"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try await process.run(stagedExecutable.path, [image.path], environment: [
            "ASAN_OPTIONS": "color=never:external_symbolizer_path='':abort_on_error=1",
            "DYLD_INSERT_LIBRARIES": runtime,
        ])
        #expect(output == "32\n")
        #expect(try Data(contentsOf: stagedExecutable) == helperBytes)
        #expect(try Data(contentsOf: binary) == original)
        #expect(try Data(contentsOf: support) == originalSupport)
        #expect(try Data(contentsOf: dependencyBinary) == originalDependency)
        #expect(try Data(contentsOf: staticArchive) == originalStaticDependency)
        let stagedFramework = NativePreviewPlatform.macOS.frameworksDirectory(in: app).appendingPathComponent(framework.lastPathComponent)
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #expect(try Data(contentsOf: stagedFramework.appendingPathComponent("FixtureKit")) == original)
        #expect(try String(contentsOf: stagedFramework.appendingPathComponent("Resources/Marker.txt"), encoding: .utf8) == "static resource")
    }

    @Test func catalystStaticFrameworkUsesItsSDKFrameworks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let platform = NativePreviewPlatform.catalyst
        let framework = root.appendingPathComponent("FixtureKit.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let binary = framework.appendingPathComponent("FixtureKit")
        let code = root.appendingPathComponent("FixtureRepresentable.swift")
        let object = root.appendingPathComponent("FixtureRepresentable.o")
        try Data("""
        import SwiftUI
        import UIKit
        public struct FixtureRepresentable: UIViewRepresentable {
            public init() {}
            public func makeUIView(context: Context) -> UIView { UIView() }
            public func updateUIView(_ view: UIView, context: Context) {}
        }
        """.utf8).write(to: code)
        let sdk = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", platform.sdk, "--show-sdk-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let support = URL(filePath: sdk).appendingPathComponent("System/iOSSupport")
        let compileCommand = ["swiftc", "-parse-as-library", "-c", "-target", platform.triple, "-sdk", sdk,
            "-Fsystem", support.appendingPathComponent("System/Library/Frameworks").path,
            "-I", support.appendingPathComponent("usr/include").path, code.path, "-o", object.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", platform.sdk] + compileCommand)
        let command = ["libtool", "-static", "-L" + root.path, object.path, "-o", binary.path]
        try previewBinaryOutput("/usr/bin/xcrun", command)
        let target = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: sdk, sdkVariant: "iosmac", architecture: "arm64", linkCommandLine: command,
            linkerWorkingDirectory: root.path, objectFiles: [object], sourceFiles: [code], debugDylibEnabled: false, isRunnable: false,
            compileCommandLine: compileCommand)
        let original = try Data(contentsOf: binary)
        let app = root.appendingPathComponent("Preview.app")
        let frameworks = platform.frameworksDirectory(in: app)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: framework, to: frameworks.appendingPathComponent(framework.lastPathComponent))
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let image = try await NativePreviewCorrection.linkStaticFramework(target, in: app, platform: platform, process: process).url
        let linked = try #require(try NativePreviewBinary.dynamicLibrary(at: image))
        #expect(linked.dependencies.contains { $0.contains("/iOSSupport/") && $0.contains("/SwiftUI.framework/") })
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", image.path])
        #expect(symbols.contains("FixtureRepresentable"))
        #expect(try Data(contentsOf: binary) == original)
    }

    @Test(arguments: [NativePreviewPlatform.iOS, .macOS])
    func stagedFrameworkRetainsItsOwnBundleAndResources(platform: NativePreviewPlatform) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("FixtureKit.framework")
        let resources = platform == .macOS ? framework.appendingPathComponent("Versions/A/Resources") : framework
        let relativeBinary = platform == .macOS ? "Versions/A/FixtureKit" : "FixtureKit"
        let binary = framework.appendingPathComponent(relativeBinary)
        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try compilePreviewLibrary(at: binary, platform: platform)
        if platform == .macOS {
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("FixtureKit").path, withDestinationPath: "Versions/Current/FixtureKit")
        }
        let identifier = "dev.lynnswap.FixtureKit"
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "FixtureKit", "CFBundleName": "FixtureKit",
                    "CFBundleDisplayName": "Framework", "CFBundlePackageType": "FMWK"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("Info.plist"))
        try Data("framework resource".utf8).write(to: resources.appendingPathComponent("Marker.txt"))
        let localization = resources.appendingPathComponent("ja.lproj")
        try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "Framework JA"], format: .xml, options: 0)
            .write(to: localization.appendingPathComponent("InfoPlist.strings"))
        try Data("renderer".utf8).write(to: helper.appendingPathComponent("XcodeMCPPreviewRenderer"))

        try NativePreviewCorrection.prepareApp(product: framework, helper: helper, app: app, platform: platform)

        let staged = platform.frameworksDirectory(in: app).appendingPathComponent("FixtureKit.framework")
        let bundle = try #require(Bundle(url: staged))
        #expect(bundle.bundleIdentifier == identifier)
        let marker = try #require(bundle.url(forResource: "Marker", withExtension: "txt"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "framework resource")
        #expect(Bundle(url: app)?.bundleIdentifier != identifier)
        let expectedFamilies: [Int]? = platform == .iOS ? [1, 2] : nil
        #expect(Bundle(url: app)?.infoDictionary?["UIDeviceFamily"] as? [Int] == expectedFamilies)
        #expect(Bundle(url: app)?.url(forResource: "Marker", withExtension: "txt") == nil)
        #expect(try NativePreviewCorrection.appName(product: framework, containingApp: nil, localization: "ja-JP") == "Framework JA")
        #expect(try Data(contentsOf: platform.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer")) == Data("renderer".utf8))
        let libraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [])
        let paths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [], registryLibraries: libraries, sourceOutput: binary)
        #expect(paths == [String(staged.appendingPathComponent(relativeBinary).path.dropFirst(app.path.count + 1))])
        #expect(try String(contentsOf: resources.appendingPathComponent("Marker.txt"), encoding: .utf8) == "framework resource")
    }

    enum FrameworkDependencyKind: CaseIterable {
        case built, prebuilt, absoluteBuilt
    }

    @Test(arguments: FrameworkDependencyKind.allCases)
    func standaloneFrameworkStagesItsTransitiveDependencies(kind: FrameworkDependencyKind) async throws {
        let prebuilt = kind == .prebuilt
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("Products")
        let source = products.appendingPathComponent("Feature.framework/Feature")
        let dependencyAlias = products.appendingPathComponent("Dependency.framework/Dependency")
        let dependency = prebuilt ? products.appendingPathComponent("Dependency.framework/Versions/A/Dependency") : dependencyAlias
        let otherDependency = root.appendingPathComponent("OtherProducts/Dependency.framework/Dependency")
        let library = (prebuilt ? products : root).appendingPathComponent("Support/libSupport.dylib")
        let absoluteSupport = products.appendingPathComponent("Vendor/libSupport.dylib")
        let leaf = products.appendingPathComponent("Vendor/libLeaf.dylib")
        let unrelated = products.appendingPathComponent("libUnrelated.dylib")
        for binary in [source, dependency, otherDependency] {
            let resources = binary.deletingLastPathComponent().appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "dev.lynnswap." + binary.lastPathComponent,
                        "CFBundleExecutable": binary.lastPathComponent, "CFBundlePackageType": "FMWK"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: resources.appendingPathComponent("Info.plist"))
        }
        if prebuilt {
            let framework = dependencyAlias.deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path,
                withDestinationPath: "A")
            try FileManager.default.createSymbolicLink(atPath: dependencyAlias.path, withDestinationPath: "Versions/Current/Dependency")
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                withDestinationPath: "Versions/Current/Resources")
        }
        let marker = dependency.deletingLastPathComponent().appendingPathComponent("Resources/Marker.txt")
        try Data("dependency resource".utf8).write(to: marker)
        try Data("unrelated dependency resource".utf8)
            .write(to: otherDependency.deletingLastPathComponent().appendingPathComponent("Resources/Marker.txt"))
        try compilePreviewLibrary(at: otherDependency, value: 1, platform: .macOS,
            installName: "@rpath/Dependency.framework/Dependency")
        let libraryIdentifier = kind != .prebuilt
            ? root.appendingPathComponent("Install/libSupport.dylib").path : "@loader_path/../../../Support/libSupport.dylib"
        if prebuilt {
            try compilePreviewLibrary(at: leaf, platform: .macOS, installName: "@rpath/libLeaf.dylib")
            try compilePreviewLibrary(at: absoluteSupport, platform: .macOS, installName: absoluteSupport.path, libraries: [leaf])
        }
        try compilePreviewLibrary(at: library, platform: .macOS, installName: libraryIdentifier,
            libraries: prebuilt ? [absoluteSupport] : [])
        try compilePreviewLibrary(at: unrelated, platform: .macOS, installName: "@rpath/libUnrelated.dylib")
        let sourceCode = root.appendingPathComponent("Feature.c")
        try Data("int preview_fixture_value(void) { return 0; }\n".utf8).write(to: sourceCode)
        let sdk = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sdkAlias = root.appendingPathComponent("MacOSX.sdk")
        try FileManager.default.createSymbolicLink(at: sdkAlias, withDestinationURL: URL(filePath: sdk))
        let unexportedSymbols = root.appendingPathComponent("FrameworkDependencyUnexportedSymbols.txt")
        try Data().write(to: unexportedSymbols)
        let dependencyLinkArguments = ["-dynamiclib", "-target", NativePreviewPlatform.macOS.triple,
            sourceCode.path, "-install_name", "@rpath/Dependency.framework/Dependency", "-o", dependency.path,
            "-L", library.deletingLastPathComponent().path, "-lSupport", "-Wl,-no_adhoc_codesign"]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang"] + dependencyLinkArguments)
        // Reserve room for changing the staged copy's dependency references.
        let sourceLinkArguments = ["-dynamiclib", "-target", NativePreviewPlatform.macOS.triple,
            sourceCode.path, "-isysroot", sdkAlias.path, "-install_name", "@rpath/Feature.framework/Feature", "-o", source.path,
            "-Wl,-headerpad_max_install_names", "-Wl,-no_adhoc_codesign"]
            + ["-Xlinker", "-unexported_symbols_list", "-Xlinker", unexportedSymbols.path]
            + (prebuilt ? ["-Wl,-rpath,@loader_path/..", "-Wl,-rpath,@loader_path/../Vendor", dependencyAlias.path]
                : ["-F", products.path, "-framework", "Dependency"])
            + (kind == .built ? ["-Wl,-rpath," + products.path] : [])
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang"] + sourceLinkArguments)
        let originalBinaries = [source, dependency, library] + (prebuilt ? [absoluteSupport, leaf] : [])
        for binary in originalBinaries + [otherDependency] {
            try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        }
        let original = try originalBinaries.map { try Data(contentsOf: $0) }
        func target(_ binary: URL, command: [String]? = nil) -> NativePreviewBuild.Target {
            NativePreviewBuild.Target(moduleName: binary.lastPathComponent, buildableName: binary.lastPathComponent,
                sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: command ?? ["-o", binary.path],
                linkerWorkingDirectory: root.path, objectFiles: [], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)
        }
        let sourceTarget = NativePreviewBuild.Target(moduleName: "Feature", buildableName: "Feature.framework",
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: sourceLinkArguments,
            linkerWorkingDirectory: root.path, objectFiles: [], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)
        var targets = prebuilt ? [sourceTarget] : [sourceTarget, target(otherDependency),
            target(dependency, command: dependencyLinkArguments), target(unrelated)]
        if kind == .absoluteBuilt { targets.append(target(library)) }
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: sourceTarget, targets: targets, platform: .macOS)

        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loaderSource = root.appendingPathComponent("Loader.c")
        try Data("#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (dlopen(argv[1], RTLD_NOW)) return 0; fputs(dlerror(), stderr); return 1; }\n".utf8)
            .write(to: loaderSource)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", loaderSource.path,
            "-Wl,-rpath,@executable_path/../Frameworks", "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        if prebuilt {
            try previewBinaryOutput(helper.appendingPathComponent("XcodeMCPPreviewRenderer").path, [source.path])
        }
        try NativePreviewCorrection.prepareApp(product: source.deletingLastPathComponent(), helper: helper, app: app,
            platform: .macOS)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: app, platform: .macOS)
        let developerDirectory = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developerDirectory)), artifacts: root)
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        let stagedLibraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [])
        for binary in originalBinaries {
            #expect(try stagedLibraries.contains { try NativePreviewBinary.matches(binary, $0) })
        }
        #expect(try !stagedLibraries.contains { try NativePreviewBinary.matches(unrelated, $0) })
        let paths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [],
            registryLibraries: stagedLibraries, sourceOutput: source)
        #expect(paths == ["Contents/Frameworks/Feature.framework/Feature"])
        let dependencyPath = try #require(dependencies.products[dependencyAlias.deletingLastPathComponent().resolvingSymlinksInPath()])
        let stagedDependency = try #require(Bundle(url: frameworks.appendingPathComponent(dependencyPath)))
        let stagedMarker = try #require(stagedDependency.url(forResource: "Marker", withExtension: "txt"))
        #expect(try String(contentsOf: stagedMarker, encoding: .utf8) == "dependency resource")
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies, in: app, platform: .macOS, process: process)
        try previewBinaryOutput(app.appendingPathComponent("Contents/MacOS/XcodeMCPPreviewRenderer").path,
            [frameworks.appendingPathComponent("Feature.framework/Feature").path])
        #expect(try originalBinaries.map { try Data(contentsOf: $0) } == original)
    }

    @Test func standaloneFrameworkTraversesInnerLibrariesWithoutCopyingItsBundleAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("Feature.framework")
        let source = framework.appendingPathComponent("Feature")
        let inner = framework.appendingPathComponent("Libraries/libInner.dylib")
        let support = root.appendingPathComponent("Support/libSupport.dylib")
        let resources = framework.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lynnswap.Feature",
            "CFBundleExecutable": "Feature", "CFBundlePackageType": "FMWK"], format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("Info.plist"))
        try Data("framework resource".utf8).write(to: resources.appendingPathComponent("Marker.txt"))
        try compilePreviewLibrary(at: support, platform: .macOS, installName: "@loader_path/../../Support/libSupport.dylib")
        try compilePreviewLibrary(at: inner, platform: .macOS, installName: "@loader_path/Libraries/libInner.dylib", libraries: [support])
        try compilePreviewLibrary(at: source, platform: .macOS, libraries: [inner])
        for binary in [source, inner, support] {
            try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        }
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", framework.path])
        let original = try [source, inner, support].map { try Data(contentsOf: $0) }
        let target = NativePreviewBuild.Target(moduleName: "Feature", buildableName: "Feature.framework",
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", source.path],
            linkerWorkingDirectory: root.path, objectFiles: [], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: target, targets: [target], platform: .macOS)
        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loaderSource = root.appendingPathComponent("Loader.c")
        try Data("#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (dlopen(argv[1], RTLD_NOW)) return 0; fputs(dlerror(), stderr); return 1; }\n".utf8)
            .write(to: loaderSource)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", loaderSource.path,
            "-Wl,-rpath,@executable_path/../Frameworks",
            "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])

        try previewBinaryOutput(helper.appendingPathComponent("XcodeMCPPreviewRenderer").path, [source.path])

        try NativePreviewCorrection.prepareApp(product: framework, helper: helper, app: app, platform: .macOS)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: app, platform: .macOS)

        let developerDirectory = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developerDirectory)), artifacts: root)
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies, in: app, platform: .macOS, process: process)

        try previewBinaryOutput(app.appendingPathComponent("Contents/MacOS/XcodeMCPPreviewRenderer").path,
            [app.appendingPathComponent("Contents/Frameworks/Feature.framework/Feature").path])
        #expect(try [source, inner, support].map { try Data(contentsOf: $0) } == original)
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/Frameworks/Feature.framework/Resources/Marker.txt"),
            encoding: .utf8) == "framework resource")
        try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--strict", app.appendingPathComponent("Contents/Frameworks/Feature.framework").path])
    }

    @Test(arguments: [false, true])
    func extensionPreviewsUseTheirOwnBundle(linkedLibrary: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("ExtensionView.swift")
        let library = root.appendingPathComponent("ExtensionPreview.o")
        let extensionPath = linkedLibrary ? "Host.app/PlugIns/Extension.appex" : "Extension.appex"
        let target = NativePreviewBuild.Target(moduleName: "Extension", buildableName: "Extension.appex",
            sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64",
            linkCommandLine: ["-o", root.appendingPathComponent("\(extensionPath)/Extension.debug.dylib").path]
                + (linkedLibrary ? [library.path] : []),
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: linkedLibrary ? [] : [source],
            debugDylibEnabled: true, isRunnable: true)
        let targets = [target] + (linkedLibrary ? [NativePreviewBuild.Target(moduleName: "ExtensionPreview",
            buildableName: "ExtensionPreview.o", sdkRoot: "iphonesimulator", sdkVariant: nil, architecture: "arm64",
            linkCommandLine: ["-o", library.path], linkerWorkingDirectory: nil, objectFiles: [],
            sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)] : [])

        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .iOS)
        #expect(selected.host.outputURL == target.outputURL)
        #expect(selected.source.moduleName == (linkedLibrary ? "ExtensionPreview" : "Extension"))
    }

    @Test func sharedAppAndExtensionSourceUsesRunnable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("SharedView.swift")
        let targets = ["Extension.appex", "Host.app"].map { product in
            NativePreviewBuild.Target(moduleName: product, buildableName: product, sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(product)/Preview.debug.dylib").path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source],
                debugDylibEnabled: true, isRunnable: product == "Host.app")
        }
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .iOS)
        #expect(selected.host.outputURL == targets[1].outputURL)
        #expect(selected.source.outputURL == targets[1].outputURL)
    }

    @Test func extensionContainingAppMustEmbedTheSourceBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Extension.appex/Extension.debug.dylib")
        try compilePreviewLibrary(at: output)
        let wrong = root.appendingPathComponent("Wrong.app/PlugIns/Extension.appex/Extension.debug.dylib")
        let matching = root.appendingPathComponent("Matching.app/PlugIns/Extension.appex/Extension.debug.dylib")
        let unselected = root.appendingPathComponent("Unselected.app/PlugIns/Extension.appex/Extension.debug.dylib")
        try compilePreviewLibrary(at: wrong, value: 1)
        for embedded in [matching, unselected] {
            try FileManager.default.createDirectory(at: embedded.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: output, to: embedded)
        }
        let hosts = ["Wrong", "Unselected", "Matching"].map { name in
            NativePreviewBuild.Target(moduleName: name, buildableName: "\(name).app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64",
                linkCommandLine: ["-o", root.appendingPathComponent("\(name).app/\(name).debug.dylib").path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [],
                debugDylibEnabled: true, isRunnable: name != "Unselected")
        }
        #expect(try NativePreviewCorrection.containingApp(for: output, targets: hosts)?.path
            == root.appendingPathComponent("Matching.app").path)
        #expect(try NativePreviewCorrection.containingApp(for: output, targets: [hosts[0]]) == nil)
    }

    @Test(arguments: [false, true])
    func preparingExtensionPreservesItsResourcesAndSharedFrameworks(nativeClient: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let containing = root.appendingPathComponent("Host.app", isDirectory: true)
        let product = containing.appendingPathComponent("PlugIns/Extension.appex", isDirectory: true)
        let helper = root.appendingPathComponent("Helper", isDirectory: true)
        let app = root.appendingPathComponent("Preview.app", isDirectory: true)
        for directory in [product.appendingPathComponent("Frameworks"), containing.appendingPathComponent("Frameworks"),
                          helper.appendingPathComponent("Frameworks")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = Data("extension resource".utf8)
        let localFramework = Data("extension framework".utf8)
        let sharedFramework = Data("shared framework".utf8)
        try resource.write(to: product.appendingPathComponent("Assets.car"))
        try localFramework.write(to: product.appendingPathComponent("Frameworks/libLocal.dylib"))
        try sharedFramework.write(to: containing.appendingPathComponent("Frameworks/libLocal.dylib"))
        try sharedFramework.write(to: containing.appendingPathComponent("Frameworks/libShared.dylib"))
        try Data("renderer".utf8).write(to: helper.appendingPathComponent("XcodeMCPPreviewRenderer"))
        let info: [String: Any] = ["CFBundleIdentifier": "dev.lynnswap.Host.Extension", "CFBundleExecutable": "Extension",
            "CFBundlePackageType": "XPC!", "MinimumOSVersion": "27.0", "UIDeviceFamily": [1],
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]]
        let originalInfo = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try originalInfo.write(to: product.appendingPathComponent("Info.plist"))

        let clientIdentifier = nativeClient ? "dev.lynnswap.PreviewClient" : nil
        try NativePreviewCorrection.prepareApp(product: product, helper: helper, app: app, containingApp: containing,
            clientIdentifier: clientIdentifier)

        #expect(try Data(contentsOf: app.appendingPathComponent("Assets.car")) == resource)
        #expect(try Data(contentsOf: app.appendingPathComponent("Frameworks/libLocal.dylib")) == localFramework)
        #expect(try Data(contentsOf: app.appendingPathComponent("Frameworks/libShared.dylib")) == sharedFramework)
        let rawInfo = try unsafe PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil)
        let stagedInfo = try #require(rawInfo as? [String: Any])
        #expect(stagedInfo["CFBundleIdentifier"] as? String == (clientIdentifier ?? "dev.lynnswap.Host.Extension"))
        #expect(stagedInfo["CFBundlePackageType"] as? String == "APPL")
        #expect(stagedInfo["UIDeviceFamily"] as? [Int] == [1])
        #expect(stagedInfo["NSExtension"] == nil)
        #expect(try Data(contentsOf: product.appendingPathComponent("Frameworks/libLocal.dylib")) == localFramework)
        #expect(try Data(contentsOf: containing.appendingPathComponent("Frameworks/libLocal.dylib")) == sharedFramework)
        #expect(try Data(contentsOf: product.appendingPathComponent("Info.plist")) == originalInfo)
    }

    @Test(arguments: [true, false])
    func activityNameUsesLocalizedContainingAppWithExtensionFallback(hasContainingApp: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("Host.app", isDirectory: true)
        let product = parent.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (bundle, identifier, info, localized) in [
            (parent, "dev.lynnswap.Host", ["CFBundleName": "Parent fallback", "CFBundleDisplayName": "Parent"],
             ["CFBundleDisplayName": "Parent JA"]),
            (product, "dev.lynnswap.Host.Widget", ["CFBundleName": "Extension"], ["CFBundleName": "Extension JA"]),
        ] {
            let localization = bundle.appendingPathComponent("ja.lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
            var propertyList = info
            propertyList["CFBundleIdentifier"] = identifier
            propertyList["CFBundleExecutable"] = "Fixture"
            propertyList["CFBundlePackageType"] = "APPL"
            propertyList["CFBundleDevelopmentRegion"] = "ja"
            try PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0)
                .write(to: bundle.appendingPathComponent("Info.plist"))
            try PropertyListSerialization.data(fromPropertyList: localized, format: .xml, options: 0)
                .write(to: localization.appendingPathComponent("InfoPlist.strings"))
        }

        let name = try NativePreviewCorrection.appName(product: product, containingApp: hasContainingApp ? parent : nil,
            localization: "ja-JP")
        #expect(name == (hasContainingApp ? "Parent JA" : "Extension JA"))
    }

    @Test func preparingAppReplacesCollidingRendererExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let product = root.appendingPathComponent("Original.app", isDirectory: true)
        let helper = root.appendingPathComponent("Helper", isDirectory: true)
        let app = root.appendingPathComponent("Preview.app", isDirectory: true)
        try FileManager.default.createDirectory(at: product.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalExecutable = Data("original executable".utf8)
        let rendererExecutable = Data("renderer executable".utf8)
        let originalFramework = Data("original framework".utf8)
        let rendererFramework = Data("renderer framework".utf8)
        let resource = Data("source resource".utf8)
        try originalExecutable.write(to: product.appendingPathComponent("XcodeMCPPreviewRenderer"))
        try rendererExecutable.write(to: helper.appendingPathComponent("XcodeMCPPreviewRenderer"))
        try originalFramework.write(to: product.appendingPathComponent("Frameworks/libPreviewRuntime.dylib"))
        try rendererFramework.write(to: helper.appendingPathComponent("Frameworks/libPreviewRuntime.dylib"))
        try resource.write(to: product.appendingPathComponent("Assets.car"))
        let info = ["CFBundleIdentifier": "dev.lynnswap.Original", "CFBundleExecutable": "XcodeMCPPreviewRenderer",
                    "CFBundlePackageType": "APPL", "MinimumOSVersion": "27.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: product.appendingPathComponent("Info.plist"))

        try NativePreviewCorrection.prepareApp(product: product, helper: helper, app: app)

        #expect(try Data(contentsOf: app.appendingPathComponent("XcodeMCPPreviewRenderer")) == rendererExecutable)
        #expect(try Data(contentsOf: app.appendingPathComponent("Frameworks/libPreviewRuntime.dylib")) == rendererFramework)
        #expect(try Data(contentsOf: app.appendingPathComponent("Assets.car")) == resource)
        let rawInfo = try unsafe PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil)
        let stagedInfo = try #require(rawInfo as? [String: Any])
        #expect(stagedInfo["CFBundleIdentifier"] as? String == "dev.lynnswap.Original")
        #expect(stagedInfo["CFBundleExecutable"] as? String == "XcodeMCPPreviewRenderer")
        #expect(try Data(contentsOf: product.appendingPathComponent("XcodeMCPPreviewRenderer")) == originalExecutable)
        #expect(try Data(contentsOf: helper.appendingPathComponent("XcodeMCPPreviewRenderer")) == rendererExecutable)
        #expect(try Data(contentsOf: product.appendingPathComponent("Frameworks/libPreviewRuntime.dylib")) == originalFramework)
    }

    @Test func rendererStartupOverridesQualifiedSettingsAndPreservesResources() throws {
        let originalScene: [String: Any] = ["UIApplicationSupportsMultipleScenes": true,
            "UISceneConfigurations": ["UIWindowSceneSessionRoleApplication": [["UISceneDelegateClassName": "Original.Scene"]]]]
        let input: [String: Any] = [
            "CFBundleIdentifier": "dev.lynnswap.Original",
            "CFBundleExecutable": "Original",
            "CFBundleExecutable-iphonesimulator~ipad": "OriginalTablet",
            "CFBundlePackageType": "FMWK",
            "CFBundlePackageType~ipad": "FMWK",
            "NSPrincipalClass": "Original.Application",
            "NSPrincipalClass-iphonesimulator": "Original.SimulatorApplication",
            "UIMainStoryboardFile": "Main",
            "UIMainStoryboardFile~ipad": "TabletMain",
            "UIApplicationSceneManifest": originalScene,
            "UIApplicationSceneManifest-iphonesimulator~ipad": originalScene,
            "NSExtension~ipad": ["NSExtensionPrincipalClass": "Original.Extension"],
            "MinimumOSVersion": "27.0",
            "CFBundleLocalizations": ["en", "ja"],
            "UIAppFonts": ["FixtureFont.otf"],
            "FixtureCustom": ["environment": "staging"],
        ]
        let output = NativePreviewCorrection.rendererInfo(input)

        #expect(output["CFBundleExecutable"] as? String == "XcodeMCPPreviewRenderer")
        #expect(output["CFBundlePackageType"] as? String == "APPL")
        #expect(output["CFBundleExecutable-iphonesimulator~ipad"] == nil)
        #expect(output["CFBundlePackageType~ipad"] == nil)
        #expect(output["NSPrincipalClass"] == nil)
        #expect(output["NSPrincipalClass-iphonesimulator"] == nil)
        #expect(output["UIMainStoryboardFile"] == nil)
        #expect(output["UIMainStoryboardFile~ipad"] == nil)
        #expect(output["UIApplicationSceneManifest-iphonesimulator~ipad"] == nil)
        #expect(output["NSExtension~ipad"] == nil)
        let manifest = try #require(output["UIApplicationSceneManifest"] as? [String: Any])
        let configurations = try #require(manifest["UISceneConfigurations"] as? [String: [[String: String]]])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == false)
        #expect(configurations["UIWindowSceneSessionRoleApplication"]?.first?["UISceneDelegateClassName"]
            == "XcodeMCPPreviewRenderer.PreviewRendererScene")
        #expect(output["MinimumOSVersion"] as? String == "27.0")
        #expect(output["CFBundleIdentifier"] as? String == "dev.lynnswap.Original")
        #expect(output["CFBundleLocalizations"] as? [String] == ["en", "ja"])
        #expect(output["UIAppFonts"] as? [String] == ["FixtureFont.otf"])
        #expect(output["FixtureCustom"] as? [String: String] == ["environment": "staging"])
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
