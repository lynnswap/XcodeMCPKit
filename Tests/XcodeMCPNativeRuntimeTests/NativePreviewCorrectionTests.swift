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
            let value = try await NativePreviewCorrection.withStagedDirectory(in: root) { directory in
                let app = directory.appendingPathComponent("PreviewAgent.app")
                stagedApp = app
                try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
                try Data("application".utf8).write(to: app.appendingPathComponent("Executable"))
                let products = app.deletingLastPathComponent().appendingPathComponent("Products/Debug")
                try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
                try Data("source image".utf8).write(to: products.appendingPathComponent("Source.dylib"))
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
        let previewCode = root.appendingPathComponent("FrameworkPreviewValue.c")
        let previewObject = root.appendingPathComponent("FrameworkPreviewValue.o")
        let packageCode = root.appendingPathComponent("Package.c")
        let packageObject = root.appendingPathComponent("Package.o")
        let mergedCode = root.appendingPathComponent("Merged.c")
        let mergedObject = root.appendingPathComponent("Merged.o")
        let mergedArchive = root.appendingPathComponent("Merged.a")
        let support = root.appendingPathComponent("Vendor/libSupport.dylib")
        let supportCode = root.appendingPathComponent("Support.c")
        try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("int support_value(void) { return 10; }".utf8).write(to: supportCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-dynamiclib", supportCode.path,
            "-Wl,-install_name,@rpath/libSupport.dylib", "-o", support.path])
        try Data("int package_value(void) { return 8; }".utf8).write(to: packageCode)
        try Data("int merged_value(void) { return 4; }".utf8).write(to: mergedCode)
        for (code, output) in [(packageCode, packageObject), (mergedCode, mergedObject)] {
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-c", code.path, "-o", output.path])
        }
        try previewBinaryOutput("/usr/bin/xcrun", ["libtool", "-static", mergedObject.path, "-o", mergedArchive.path])
        try Data("""
        extern int support_value(void), package_value(void), merged_value(void);
        extern const char *zlibVersion(void);
        int static_preview_value(void) { return support_value() + package_value() + merged_value() + (zlibVersion() != 0 ? 0 : 1); }
        """.utf8).write(to: previewCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-c", previewCode.path, "-o", previewObject.path])
        try Data("""
        import Foundation
        @objc(HostedStaticResourceToken) public final class HostedStaticResourceToken: NSObject {}
        @_cdecl("static_core_value") public func coreValue() -> Int32 { 7 }
        """.utf8).write(to: coreSource)
        try Data("""
        import SwiftUI
        #Preview { Text("Unreferenced preview member") }
        """.utf8).write(to: source)
        let sdk = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let compileCommand = ["swiftc", "-parse-as-library", "-c", "-module-name", "FixtureKit", "-target",
            NativePreviewPlatform.macOS.triple, "-Fsystem", URL(filePath: sdk).appendingPathComponent("System/Library/Frameworks").path,
            source.path, "-o", object.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + compileCommand)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-parse-as-library", "-c",
            "-module-name", "FixtureKit", "-target", NativePreviewPlatform.macOS.triple, coreSource.path, "-o", core.path])
        let archiveCommand = ["libtool", "-static", core.path, object.path, previewObject.path, mergedArchive.path, "-o", binary.path]
        try previewBinaryOutput("/usr/bin/xcrun", archiveCommand)
        let target = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: archiveCommand,
            linkerWorkingDirectory: nil, objectFiles: [core, object, previewObject], sourceFiles: [source, coreSource, previewCode], debugDylibEnabled: false,
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
        let appCode = root.appendingPathComponent("Host.m")
        let appObject = root.appendingPathComponent("Host.o")
        try Data("""
        #import <Foundation/Foundation.h>
        extern int static_core_value(void), support_value(void), package_value(void), merged_value(void);
        int app_host_value(void) { return static_core_value() + support_value() + package_value(); }
        int main(void) { return 99; }
        """.utf8).write(to: appCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-c", appCode.path, "-o", appObject.path])
        let categoryCode = root.appendingPathComponent("Category.m")
        let categoryObject = root.appendingPathComponent("Category.o")
        let categoryArchive = root.appendingPathComponent("Category.a")
        try Data("""
        #import <Foundation/Foundation.h>
        @interface NSObject (PreviewCategory)
        -(int)previewCategoryValue;
        @end
        @implementation NSObject (PreviewCategory)
        -(int)previewCategoryValue { return 12; }
        @end
        """.utf8).write(to: categoryCode)
        let runtimeCode = root.appendingPathComponent("RuntimeOnly.m")
        let runtimeObject = root.appendingPathComponent("RuntimeOnly.o")
        let runtimeArchive = root.appendingPathComponent("RuntimeOnly.a")
        try Data("""
        #import <Foundation/Foundation.h>
        @interface PreviewRuntimeOnly : NSObject
        -(int)runtimeValue;
        @end
        @implementation PreviewRuntimeOnly
        -(int)runtimeValue { return 13; }
        @end
        """.utf8).write(to: runtimeCode)
        for (code, output, archive) in [(categoryCode, categoryObject, categoryArchive), (runtimeCode, runtimeObject, runtimeArchive)] {
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-c", code.path, "-o", output.path])
            try previewBinaryOutput("/usr/bin/xcrun", ["libtool", "-static", output.path, "-o", archive.path])
        }
        let fileList = root.appendingPathComponent("Host.LinkFileList")
        let listedObjects = [appObject.lastPathComponent, packageObject.lastPathComponent] + (forceLoad ? [] : [core.lastPathComponent])
        try Data((listedObjects.joined(separator: "\n") + "\n").utf8).write(to: fileList)
        let compiler = try previewBinaryOutput("/usr/bin/xcrun", ["--find", "clang"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let swiftLibraries = URL(filePath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/macosx")
        let dependencyInfo = root.appendingPathComponent("Host_dependency_info.dat")
        let ltoOutput = root.appendingPathComponent("Host_lto.o")
        var appCommand = [compiler, "-target", NativePreviewPlatform.macOS.triple, "-isysroot", sdk, "-dynamiclib", "-fobjc-link-runtime",
            "-filelist", fileList.path, "-F", root.path, "-L", support.deletingLastPathComponent().path,
            "-lSupport", "-lz", "-L" + swiftLibraries.path, "-L/usr/lib/swift", "-framework", "Foundation", categoryArchive.path,
            "-Xlinker", "-force_load", "-Xlinker", runtimeArchive.path, "-Xlinker", "-alias", "-Xlinker", "_main",
            "-Xlinker", "___debug_main_executable_dylib_entry_point", "-install_name", "@rpath/Host.debug.dylib",
            "-Xlinker", "-dependency_info", "-Xlinker", dependencyInfo.path, "-Xlinker", "-object_path_lto", "-Xlinker", ltoOutput.path,
            "-Xlinker", "-no_adhoc_codesign", "-o", appImage.path]
        if forceLoad { appCommand.append("-ObjC") }
        else { appCommand += ["-framework", "FixtureKit"] }
        appCommand += ["-Xlinker", "-force_load", "-Xlinker", forceLoad ? binary.path : mergedArchive.path]
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        _ = try await process.run(compiler, Array(appCommand.dropFirst()), directory: root)
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", appImage.path])
        let appSymbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", appImage.path])
        #expect(appSymbols.contains("_static_preview_value") == forceLoad)
        #expect(!NativePreviewCorrection.registryNames(in: appSymbols).isEmpty == forceLoad)
        let protectedFiles = [binary, support, appImage, fileList, dependencyInfo, mergedArchive]
        let originals = try protectedFiles.map { try Data(contentsOf: $0) }
        let app = NativePreviewBuild.Target(moduleName: "Host", buildableName: "Host.app", sdkRoot: "macosx",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: appCommand,
            linkerWorkingDirectory: root.path, objectFiles: [appObject, packageObject], sourceFiles: [], debugDylibEnabled: true, isRunnable: true)
        let hosted = try NativePreviewCorrection.selectTarget([target, app], source: source, platform: .macOS)
        #expect(hosted.host.moduleName == "Host")
        #expect(hosted.source.moduleName == "FixtureKit")
        let helper = root.appendingPathComponent("Helper")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loader = root.appendingPathComponent("Loader.m")
        try Data("""
        #import <Foundation/Foundation.h>
        #include <dlfcn.h>
        @interface NSObject (PreviewValues)
        -(int)previewCategoryValue;
        -(int)runtimeValue;
        @end
        int main(int argc, char **argv) {
            @autoreleasepool {
                void *image = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
                if (!image) { fputs(dlerror(), stderr); return 1; }
                Class token = NSClassFromString(@"HostedStaticResourceToken");
                if (!token) return 3;
                NSBundle *owner = [NSBundle bundleForClass:token];
                puts(owner.bundleIdentifier.UTF8String ?: "<missing>");
                puts([[NSString alloc] initWithContentsOfURL:[owner URLForResource:@"Marker" withExtension:@"txt"]
                    encoding:NSUTF8StringEncoding error:nil].UTF8String ?: "<missing>");
                puts(owner.bundleURL.URLByResolvingSymlinksInPath.path.UTF8String);
                if (argc > 3) return 0;
                int (*value)(void) = dlsym(image, "static_preview_value");
                int (*host)(void) = dlsym(image, "app_host_value");
                Class runtime = NSClassFromString(@"PreviewRuntimeOnly");
                BOOL category = [NSObject instancesRespondToSelector:@selector(previewCategoryValue)];
                if (!value || !host || !runtime || category != (strcmp(argv[2], "1") == 0)) return 2;
                puts(NSBundle.mainBundle.bundleIdentifier.UTF8String);
                puts([[NSString alloc] initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"Marker" withExtension:@"txt"]
                    encoding:NSUTF8StringEncoding error:nil].UTF8String);
                printf("%d %d %d %d\\n", value(), host(), category ? [NSObject.new previewCategoryValue] : 0, [[runtime new] runtimeValue]);
            }
        }
        """.utf8).write(to: loader)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-framework", "Foundation", loader.path,
            "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        let baseline = try await process.run(helper.appendingPathComponent("XcodeMCPPreviewRenderer").path,
            [appImage.path, forceLoad ? "1" : "0", "baseline"],
            environment: ["DYLD_LIBRARY_PATH": support.deletingLastPathComponent().path])
        #expect(baseline == "dev.lynnswap.StaticHost\nhost resource\n\(appURL.resolvingSymlinksInPath().path)\n")
        let staged = root.appendingPathComponent("Preview.app")
        let products = try NativePreviewCorrection.prepareApp(product: appURL, helper: helper, app: staged, platform: .macOS,
            staticProduct: true)
        let linked = try await NativePreviewCorrection.linkStaticProduct(hosted.source, host: hosted.host, in: staged, products: products, platform: .macOS, process: process)
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: [hosted.source], targets: [target, app],
            platform: .macOS, in: products, linkedImages: [try #require(hosted.source.outputURL).resolvingSymlinksInPath(): linked])
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: products)
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies, in: products, process: process)
        let libraries = try NativePreviewCorrection.registryLibraries(in: staged, previewLibraries: [linked.url])
        let paths = try NativePreviewCorrection.libraryPaths(in: staged, previewLibraries: [linked.url], registryLibraries: libraries,
            sourceOutput: linked.url)
        #expect(paths == ["Contents/Frameworks/XcodeMCPPreviewSource.dylib"])
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", linked.url.path])
        #expect(!NativePreviewCorrection.registryNames(in: symbols).isEmpty)
        try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", staged.path])
        try await process.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", staged.path])
        let executable = staged.appendingPathComponent("Contents/MacOS/XcodeMCPPreviewRenderer")
        #expect(try await process.run(executable.path, [linked.url.path, forceLoad ? "1" : "0"])
            == "dev.lynnswap.StaticHost\nhost resource\n\(staged.resolvingSymlinksInPath().path)\n"
                + "dev.lynnswap.StaticHost\nhost resource\n22 25 \(forceLoad ? 12 : 0) 13\n")
        for (file, original) in zip(protectedFiles, originals) { #expect(try Data(contentsOf: file) == original, "\(file.path)") }
        #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Frameworks/FixtureKit.framework").path))
    }

    @Test func staticWidgetPreviewRetainsItsNativeExtensionHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Container.app")
        let product = parent.appendingPathComponent("Contents/PlugIns/Widget.appex")
        let image = product.appendingPathComponent("Contents/MacOS/Widget.debug.dylib")
        let executable = product.appendingPathComponent("Contents/MacOS/Widget")
        let existing = parent.appendingPathComponent("Contents/Frameworks/Existing.framework/Existing")
        let dependency = root.appendingPathComponent("Products/PreviewOnly.framework/PreviewOnly")
        let leaf = root.appendingPathComponent("Products/libPreviewLeaf.dylib")
        let archive = root.appendingPathComponent("StaticWidget.a")
        for (bundle, name, type) in [(parent, "Container", "APPL"), (product, "Widget", "XPC!")] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "dev.lynnswap." + name, "CFBundleExecutable": name,
                                     "CFBundleName": name, "CFBundlePackageType": type]
            if type == "XPC!" { info["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"] }
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data((name + " resource").utf8).write(to: bundle.appendingPathComponent("Contents/Resources/Marker.txt"))
        }
        for binary in [existing, dependency] {
            let resources = binary.deletingLastPathComponent().appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "dev.lynnswap." + binary.lastPathComponent,
                        "CFBundleExecutable": binary.lastPathComponent, "CFBundlePackageType": "FMWK"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: resources.appendingPathComponent("Info.plist"))
            try Data((binary.lastPathComponent + " resource").utf8).write(to: resources.appendingPathComponent("Marker.txt"))
        }
        let leafCode = root.appendingPathComponent("Leaf.c")
        try Data("int preview_leaf_value(void) { return 5; }".utf8).write(to: leafCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-dynamiclib", leafCode.path,
            "-install_name", "@rpath/libPreviewLeaf.dylib", "-o", leaf.path])
        for (binary, token, function, value) in [(existing, "NativeExistingToken", "existing_value", "11"),
                                                (dependency, "NativePreviewOnlyToken", "preview_dependency_value", "13 + preview_leaf_value()")] {
            let code = root.appendingPathComponent(binary.lastPathComponent + ".m")
            try Data("""
            #import <Foundation/Foundation.h>
            extern int preview_leaf_value(void);
            @interface \(token) : NSObject @end
            @implementation \(token) @end
            int \(function)(void) { return \(value); }
            """.utf8).write(to: code)
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-dynamiclib", "-framework", "Foundation", code.path,
                "-install_name", "@rpath/\(binary.lastPathComponent).framework/\(binary.lastPathComponent)",
                "-Wl,-headerpad_max_install_names", "-o", binary.path] + (binary == dependency ? [leaf.path] : []))
        }
        let coreCode = root.appendingPathComponent("Core.m")
        let coreObject = root.appendingPathComponent("Core.o")
        let previewCode = root.appendingPathComponent("PreviewValue.c")
        let previewObject = root.appendingPathComponent("PreviewValue.o")
        let source = root.appendingPathComponent("WidgetPreview.swift")
        let registryObject = root.appendingPathComponent("WidgetPreview.o")
        try Data("""
        #import <Foundation/Foundation.h>
        @interface NativeWidgetToken : NSObject @end
        @implementation NativeWidgetToken @end
        int static_core_value(void) { return 7; }
        """.utf8).write(to: coreCode)
        try Data("""
        __asm__(".linker_option \\\"-framework\\\", \\\"PreviewOnly\\\"");
        extern int preview_dependency_value(void);
        int static_preview_value(void) { return preview_dependency_value() + 3; }
        """.utf8).write(to: previewCode)
        for (code, object) in [(coreCode, coreObject), (previewCode, previewObject)] {
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-c", code.path, "-o", object.path])
        }
        try Data("import SwiftUI\n#Preview { Text(\"Static widget preview\") }\n".utf8).write(to: source)
        let compileCommand = ["swiftc", "-parse-as-library", "-c", "-module-name", "StaticWidget", "-target",
            NativePreviewPlatform.macOS.triple, "-F", dependency.deletingLastPathComponent().deletingLastPathComponent().path,
            "-L", leaf.deletingLastPathComponent().path, source.path, "-o", registryObject.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + compileCommand)
        let archiveCommand = ["libtool", "-static", coreObject.path, previewObject.path, registryObject.path, "-o", archive.path]
        try previewBinaryOutput("/usr/bin/xcrun", archiveCommand)
        let sourceTarget = NativePreviewBuild.Target(moduleName: "StaticWidget", buildableName: archive.lastPathComponent,
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: archiveCommand,
            linkerWorkingDirectory: root.path, objectFiles: [coreObject, previewObject, registryObject], sourceFiles: [source],
            debugDylibEnabled: false, isRunnable: false, compileCommandLine: compileCommand)
        let hostCode = root.appendingPathComponent("Widget.m")
        let hostObject = root.appendingPathComponent("Widget.o")
        try Data("""
        #import <Foundation/Foundation.h>
        extern int static_core_value(void), existing_value(void);
        int widget_host_value(void) { return static_core_value() + existing_value(); }
        """.utf8).write(to: hostCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-c", hostCode.path, "-o", hostObject.path])
        let compiler = try previewBinaryOutput("/usr/bin/xcrun", ["--find", "clang"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sdk = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let swiftLibraries = URL(filePath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/macosx")
        let hostCommand = [compiler, "-target", NativePreviewPlatform.macOS.triple, "-isysroot", sdk, "-dynamiclib", "-fobjc-link-runtime",
            hostObject.path, archive.path, "-framework", "Foundation", "-F", existing.deletingLastPathComponent().deletingLastPathComponent().path,
            "-framework", "Existing", "-L" + swiftLibraries.path, "-L/usr/lib/swift", "-install_name", "@rpath/Widget.debug.dylib",
            "-Wl,-no_adhoc_codesign", "-o", image.path]
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        try await process.run(compiler, Array(hostCommand.dropFirst()), directory: root)
        let host = NativePreviewBuild.Target(moduleName: "Widget", buildableName: "Widget.appex", sdkRoot: "macosx",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: hostCommand, linkerWorkingDirectory: root.path,
            objectFiles: [hostObject], sourceFiles: [], debugDylibEnabled: true, isRunnable: false)
        let loader = root.appendingPathComponent("WidgetStub.m")
        try Data("""
        #import <Foundation/Foundation.h>
        #include <dlfcn.h>
        extern int widget_host_value(void);
        int main(void) {
            @autoreleasepool {
                int (*preview)(void) = dlsym(RTLD_DEFAULT, "static_preview_value");
                NSMutableDictionary *result = [@{@"hostValue": @(widget_host_value()),
                    @"previewValue": preview ? @(preview()) : NSNull.null} mutableCopy];
                for (NSString *name in @[@"main", @"NativeWidgetToken", @"NativeExistingToken", @"NativePreviewOnlyToken"]) {
                    Class token = NSClassFromString(name);
                    NSBundle *bundle = [name isEqualToString:@"main"] ? NSBundle.mainBundle : token ? [NSBundle bundleForClass:token] : nil;
                    if (!bundle) continue;
                    result[name] = @{@"identifier": bundle.bundleIdentifier ?: NSNull.null,
                        @"path": bundle.bundleURL.URLByResolvingSymlinksInPath.path,
                        @"resource": [[NSString alloc] initWithContentsOfURL:[bundle URLForResource:@"Marker" withExtension:@"txt"]
                            encoding:NSUTF8StringEncoding error:nil] ?: NSNull.null};
                }
                NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                fwrite(data.bytes, 1, data.length, stdout);
            }
        }
        """.utf8).write(to: loader)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-framework", "Foundation", loader.path, image.path,
            "-Wl,-rpath,@executable_path", "-Wl,-rpath,@executable_path/../../../../Frameworks", "-o", executable.path])
        let parentCode = root.appendingPathComponent("Container.c")
        try Data("int main(void) { return 0; }".utf8).write(to: parentCode)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", parentCode.path,
            "-o", parent.appendingPathComponent("Contents/MacOS/Container").path])
        for binary in [leaf, dependency.deletingLastPathComponent(), existing.deletingLastPathComponent(), image] {
            try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        }
        let entitlements = root.appendingPathComponent("Entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.get-task-allow": true], format: .xml, options: 0)
            .write(to: entitlements)
        for bundle in [product, parent] {
            try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, bundle.path])
        }
        let originalSymbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", image.path])
        #expect(!originalSymbols.contains("_static_preview_value"))
        #expect(NativePreviewCorrection.registryNames(in: originalSymbols).isEmpty)
        let baseline = try await process.run(executable.path, [])
        let files = try #require(FileManager.default.enumerator(at: parent, includingPropertiesForKeys: [.isRegularFileKey]))
        let protectedFiles = try files.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            + [archive, dependency, leaf]
        let originalBytes = try protectedFiles.map { try Data(contentsOf: $0) }
        let staged = try await NativePreviewCorrection.prepareNativeExtension(source: sourceTarget, host: host, containingApp: parent,
            in: root.appendingPathComponent("NativePreview"), targets: [sourceTarget, host], platform: .macOS, process: process)
        let stagedProduct = staged.appendingPathComponent("Contents/PlugIns/Widget.appex")
        let stagedImage = stagedProduct.appendingPathComponent("Contents/MacOS/Widget.debug.dylib")
        let augmented = try await process.run(stagedProduct.appendingPathComponent("Contents/MacOS/Widget").path, [])
        for (output, app, hasPreview) in [(baseline, parent, false), (augmented, staged, true)] {
            let result = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            #expect(result["hostValue"] as? Int == 18)
            if hasPreview { #expect(result["previewValue"] as? Int == 21) }
            else { #expect(result["previewValue"] is NSNull) }
            for key in ["main", "NativeWidgetToken"] {
                let bundle = try #require(result[key] as? [String: Any])
                #expect(bundle["identifier"] as? String == "dev.lynnswap.Widget")
                #expect(bundle["path"] as? String == app.appendingPathComponent("Contents/PlugIns/Widget.appex").resolvingSymlinksInPath().path)
                #expect(bundle["resource"] as? String == "Widget resource")
            }
            let existingBundle = try #require(result["NativeExistingToken"] as? [String: Any])
            #expect(existingBundle["identifier"] as? String == "dev.lynnswap.Existing")
            #expect(existingBundle["path"] as? String == app.appendingPathComponent("Contents/Frameworks/Existing.framework").resolvingSymlinksInPath().path)
            #expect(existingBundle["resource"] as? String == "Existing resource")
            if hasPreview {
                let previewBundle = try #require(result["NativePreviewOnlyToken"] as? [String: Any])
                #expect(previewBundle["identifier"] as? String == "dev.lynnswap.PreviewOnly")
                #expect(previewBundle["resource"] as? String == "PreviewOnly resource")
                let path = try #require(previewBundle["path"] as? String)
                var relationship: FileManager.URLRelationship = .other
                try FileManager.default.getRelationship(&relationship,
                    ofDirectoryAt: app.appendingPathComponent("Contents/Frameworks/PreviewDependencies"), toItemAt: URL(filePath: path))
                #expect(relationship == .contains)
            } else { #expect(result["NativePreviewOnlyToken"] == nil) }
        }
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", stagedImage.path])
        #expect(symbols.contains("_static_preview_value"))
        #expect(!NativePreviewCorrection.registryNames(in: symbols).isEmpty)
        #expect(try NativePreviewBinary.dynamicLibrary(at: stagedImage)?.identifier == "@rpath/Widget.debug.dylib")
        #expect(try NativePreviewBinary.matches(executable, stagedProduct.appendingPathComponent("Contents/MacOS/Widget")))
        for bundle in [stagedProduct, staged] {
            try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
            let output = try await process.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", bundle.path])
            let preserved = try #require(PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any])
            #expect(preserved["com.apple.security.get-task-allow"] as? Bool == true)
        }
        for (file, original) in zip(protectedFiles, originalBytes) { #expect(try Data(contentsOf: file) == original, "\(file.path)") }
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
        import Foundation
        import Dependency
        import StaticDependency
        @objc(StaticResourceToken) public final class StaticResourceToken: NSObject {}
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
        let loader = root.appendingPathComponent("Loader.m")
        try Data("""
        #import <Foundation/Foundation.h>
        #include <dlfcn.h>
        #include <objc/runtime.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        int main(int argc, char **argv) {
            @autoreleasepool {
                if (!dlsym(RTLD_DEFAULT, "__asan_init") || !getenv("ASAN_OPTIONS") ||
                    strcmp(getenv("ASAN_OPTIONS"), "color=never:external_symbolizer_path='':abort_on_error=1")) return 2;
                void *image = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
                if (!image) { fputs(dlerror(), stderr); return 1; }
                int (*value)(void) = dlsym(image, "static_preview_value");
                if (!value) { fputs(dlerror(), stderr); return 1; }
                Class token = NSClassFromString(@"StaticResourceToken");
                if (!token) { fputs("Source class was not loaded", stderr); return 1; }
                NSBundle *owner = [NSBundle bundleForClass:token];
                NSDictionary *record = @{
                    @"value": @(value()),
                    @"ownerURL": owner.bundleURL.path,
                    @"ownerIdentifier": owner.bundleIdentifier ?: NSNull.null,
                    @"markerURL": [owner URLForResource:@"Marker" withExtension:@"txt"].path ?: NSNull.null,
                    @"mainIdentifier": NSBundle.mainBundle.bundleIdentifier ?: NSNull.null,
                    @"mainURL": NSBundle.mainBundle.bundleURL.path,
                    @"imagePath": [NSString stringWithUTF8String:class_getImageName(token)]
                };
                NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
                fwrite(data.bytes, 1, data.length, stdout);
                return 0;
            }
        }
        """.utf8).write(to: loader)
        let executable = helper.appendingPathComponent("XcodeMCPPreviewRenderer")
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", "-fobjc-arc",
            "-framework", "Foundation", loader.path, "-o", executable.path])
        let helperBytes = try Data(contentsOf: executable)
        let app = root.appendingPathComponent("Staged/Preview.app")
        let agent = try previewAgent(in: root, helper: helper)
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: false)
        let products = try NativePreviewCorrection.prepareApp(product: agent, sourceProduct: framework, helper: helper, app: app, platform: .macOS,
            staticProduct: true)
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let linked = try await NativePreviewCorrection.linkStaticProduct(target, in: app, products: products, platform: .macOS, process: process)
        let image = linked.url
        let runtime = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang",
            "-print-file-name=libclang_rt.asan_osx_dynamic.dylib"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeEnvironment = [
            "ASAN_OPTIONS": "color=never:external_symbolizer_path='':abort_on_error=1",
            "DYLD_INSERT_LIBRARIES": runtime,
        ]
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: [target], targets: [target], platform: .macOS,
            in: products, linkedImages: [try #require(target.outputURL).resolvingSymlinksInPath(): linked], environment: nativeEnvironment)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: products)
        let libraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [image], products: products)
        let paths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [image], registryLibraries: libraries,
            sourceOutput: image, products: products)
        #expect(paths == ["../Products/" + products.lastPathComponent + "/XcodeMCPPreviewSource.dylib"])
        #expect(try NativePreviewCorrection.programLibraries(previewLibraries: libraries, output: image) == [image.resolvingSymlinksInPath()])
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-j", image.path]).split(whereSeparator: \.isNewline)
        #expect(symbols.contains("_static_preview_value"))
        #expect(symbols.contains("_main"))
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies, in: products, process: process)
        let stagedExecutable = NativePreviewPlatform.macOS.executableDirectory(in: app).appendingPathComponent(executable.lastPathComponent)
        let helperIdentifier = try #require(Bundle(url: agent)?.bundleIdentifier)
        let text = try await process.run(stagedExecutable.path, [app.appendingPathComponent(paths[0]).path], environment: nativeEnvironment)
        let record = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(record["value"] as? Int == 32)
        #expect(record["ownerIdentifier"] is NSNull)
        #expect(record["markerURL"] is NSNull)
        let ownerURL = URL(filePath: try #require(record["ownerURL"] as? String))
        #expect(ownerURL.resolvingSymlinksInPath().path == products.resolvingSymlinksInPath().path)
        #expect(record["mainIdentifier"] as? String == helperIdentifier)
        let mainURL = URL(filePath: try #require(record["mainURL"] as? String))
        #expect(mainURL.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
        let imageURL = URL(filePath: try #require(record["imagePath"] as? String))
        #expect(imageURL.resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: stagedExecutable) == helperBytes)
        #expect(try Data(contentsOf: binary) == original)
        #expect(try Data(contentsOf: support) == originalSupport)
        #expect(try Data(contentsOf: dependencyBinary) == originalDependency)
        #expect(try Data(contentsOf: staticArchive) == originalStaticDependency)
        let stagedFramework = products.appendingPathComponent(framework.lastPathComponent)
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--strict", image.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--strict", stagedFramework.path])
        #expect(try Data(contentsOf: stagedFramework.appendingPathComponent("FixtureKit")) == original)
        #expect(try String(contentsOf: stagedFramework.appendingPathComponent("Resources/Marker.txt"), encoding: .utf8) == "static resource")

        let installedApp = root.appendingPathComponent("Installed/Preview.app")
        try FileManager.default.createDirectory(at: installedApp.deletingLastPathComponent(), withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: app, to: installedApp)
        try FileManager.default.copyItem(at: products.deletingLastPathComponent(),
            to: installedApp.deletingLastPathComponent().appendingPathComponent("Products"))
        try NativePreviewCorrection.removeStagedApp(app)
        let installedExecutable = NativePreviewPlatform.macOS.executableDirectory(in: installedApp).appendingPathComponent(executable.lastPathComponent)
        let installedText = try await process.run(installedExecutable.path,
            [installedApp.appendingPathComponent(paths[0]).path], environment: nativeEnvironment)
        let installed = try #require(JSONSerialization.jsonObject(with: Data(installedText.utf8)) as? [String: Any])
        #expect(installed["value"] as? Int == 32)
        #expect(installed["ownerIdentifier"] is NSNull)
        #expect(installed["mainIdentifier"] as? String == helperIdentifier)
        let installedOwner = URL(filePath: try #require(installed["ownerURL"] as? String))
        #expect(installedOwner.resolvingSymlinksInPath().path == installedApp.deletingLastPathComponent()
            .appendingPathComponent("Products/" + products.lastPathComponent).resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: products.deletingLastPathComponent().path))
        let rebuiltFramework = root.appendingPathComponent("OtherDestination/FixtureKit.framework")
        try FileManager.default.createDirectory(at: rebuiltFramework.deletingLastPathComponent(), withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: framework, to: rebuiltFramework)
        let refreshedProducts = try NativePreviewCorrection.prepareApp(product: agent, sourceProduct: rebuiltFramework, helper: helper, app: app, platform: .macOS,
            staticProduct: true)
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #expect(try Data(contentsOf: refreshedProducts.appendingPathComponent("FixtureKit.framework/FixtureKit")) == original)
    }

    enum ArchiveLinkKind: CaseIterable {
        case dynamicDependency, objectDependency, hostedObject
    }

    @Test(arguments: ArchiveLinkKind.allCases)
    func staticProductsRetainArchiveMembersNeededByTheirClients(kind: ArchiveLinkKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("Staged/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let baseDependency = root.appendingPathComponent("BaseDependency.o")
        let baseSource = root.appendingPathComponent("BaseSource.o")
        let dependencyObject = root.appendingPathComponent("Dependency-part.o")
        let sourceObject = root.appendingPathComponent("Source-part.o")
        for (object, body) in [
            (baseDependency, "int base_dependency_value(void) { return 4; }"),
            (baseSource, "int base_source_value(void) { return 7; }"),
            (dependencyObject, "extern int base_dependency_value(void); int dependency_value(void) { return base_dependency_value(); }"),
            (sourceObject, "extern int base_source_value(void), dependency_value(void); int source_value(void) { return base_source_value() + dependency_value(); }"),
        ] {
            let code = object.appendingPathExtension("c")
            try Data(body.utf8).write(to: code)
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-target",
                NativePreviewPlatform.macOS.triple, "-c", code.path, "-o", object.path])
        }
        let archive = root.appendingPathComponent("Base.a")
        let archiveCommand = ["libtool", "-static", baseDependency.path, baseSource.path, "-o", archive.path]
        try previewBinaryOutput("/usr/bin/xcrun", archiveCommand)
        let base = NativePreviewBuild.Target(moduleName: "Base", buildableName: "Base.a", sdkRoot: "macosx",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: archiveCommand, linkerWorkingDirectory: root.path,
            objectFiles: [baseDependency, baseSource], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)
        let dynamicDependency = kind == .dynamicDependency
        let dependencyOutput = root.appendingPathComponent(dynamicDependency ? "Dependency.dylib" : "Dependency.o")
        let dependencyCommand = ["clang", "-target", NativePreviewPlatform.macOS.triple]
            + (dynamicDependency ? ["-dynamiclib"] : ["-r", "-nostdlib"])
            + [dependencyObject.path, archive.path, "-o", dependencyOutput.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + dependencyCommand)
        let dependency = NativePreviewBuild.Target(moduleName: "Dependency", buildableName: dependencyOutput.lastPathComponent,
            sdkRoot: "macosx", sdkVariant: nil, architecture: "arm64", linkCommandLine: dependencyCommand,
            linkerWorkingDirectory: root.path, objectFiles: [dependencyObject], sourceFiles: [dependencyObject.appendingPathExtension("c")],
            debugDylibEnabled: false, isRunnable: false, dependencies: kind == .hostedObject ? [] : [base])
        let sourceOutput = root.appendingPathComponent("Source.o")
        let fileList = root.appendingPathComponent("Source.LinkFileList")
        try (sourceObject.path + "\n").write(to: fileList, atomically: true, encoding: .utf8)
        let sourceCommand = ["clang", "-r", "-nostdlib", "-target", NativePreviewPlatform.macOS.triple,
            "-filelist", fileList.path, "-o", sourceOutput.path]
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + sourceCommand)
        let source = NativePreviewBuild.Target(moduleName: "Source", buildableName: "Source.o", sdkRoot: "macosx",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: sourceCommand, linkerWorkingDirectory: root.path,
            objectFiles: [sourceObject], sourceFiles: [sourceObject.appendingPathExtension("c")],
            debugDylibEnabled: false, isRunnable: false, dependencies: [base, dependency])
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let selectedSource: NativePreviewBuild.Target
        let selectedHost: NativePreviewBuild.Target?
        if kind == .hostedObject {
            let hostOutput = root.appendingPathComponent("Host.app/Contents/MacOS/Host.debug.dylib")
            try FileManager.default.createDirectory(at: hostOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            let compiler = try previewBinaryOutput("/usr/bin/xcrun", ["--find", "clang"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sdk = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let command = [compiler, "-dynamiclib", "-target", NativePreviewPlatform.macOS.triple, "-isysroot", sdk,
                sourceOutput.path, dependencyOutput.path, archive.path, "-o", hostOutput.path]
            try await process.run(command[0], Array(command.dropFirst()))
            let host = NativePreviewBuild.Target(moduleName: "Host", buildableName: "Host.app", sdkRoot: "macosx",
                sdkVariant: nil, architecture: "arm64", linkCommandLine: command, linkerWorkingDirectory: root.path,
                objectFiles: [sourceObject], sourceFiles: [], debugDylibEnabled: true, isRunnable: true)
            let selection = try NativePreviewCorrection.selectTarget([dependency, host], source: dependencyObject.appendingPathExtension("c"), platform: .macOS)
            #expect(selection.source.outputURL == dependencyOutput)
            #expect(selection.host.outputURL == hostOutput)
            selectedSource = selection.source
            selectedHost = selection.host
        } else {
            selectedSource = source
            selectedHost = nil
        }
        let image = try await NativePreviewCorrection.linkStaticProduct(selectedSource, host: selectedHost,
            in: root.appendingPathComponent("Staged/Preview.app"),
            products: products, platform: .macOS, process: process)
        let symbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-jU", image.url.path]).split(whereSeparator: \.isNewline)
        #expect(symbols.contains("_base_source_value"))
    }

    enum HostlessPackageKind: CaseIterable {
        case automatic, dynamicDependency, dynamicSource, staticFrameworkDependency
    }

    @Test(arguments: HostlessPackageKind.allCases)
    func hostlessPackageObjectsRetainTheirAgentAndResourceOwners(kind: HostlessPackageKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeProducts = root.appendingPathComponent("Build/Products/Debug")
        try FileManager.default.createDirectory(at: nativeProducts, withIntermediateDirectories: true)
        var targets: [NativePreviewBuild.Target] = []
        var resourceURLs: [URL] = []
        let frameworkSupport = kind != .automatic
        let privateSupport = root.appendingPathComponent("Private/libPrivateSupport.dylib")
        if frameworkSupport {
            try compilePreviewLibrary(at: privateSupport, value: 7, platform: .macOS, installName: privateSupport.path)
            try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", privateSupport.path])
        }
        for name in ["Source", "Support"] {
            let framework = frameworkSupport && name == "Support"
            let dynamic = framework && kind != .staticFrameworkDependency
            let source = root.appendingPathComponent(name + ".swift")
            let object = root.appendingPathComponent(name + "-part.o")
            let output = nativeProducts.appendingPathComponent(framework
                ? "PackageFrameworks/Support.framework/Versions/A/Support" : name + ".o")
            let body = name == "Source"
                ? "@_silgen_name(\"support_value\") func supportValue() -> Int32\n@_cdecl(\"source_value\") public func value() -> Int32 { supportValue() + 3 }"
                : framework
                    ? "@_silgen_name(\"preview_fixture_value\") func privateValue() -> Int32\n@_cdecl(\"support_value\") public func value() -> Int32 { privateValue() }"
                    : "@_cdecl(\"support_value\") public func value() -> Int32 { 7 }"
            try Data("""
            import Foundation
            @objc(Hostless\(name)Token) public final class Token: NSObject {
                @objc public static func moduleBundle() -> Bundle { .module }
            }
            extension Bundle {
                static let module: Bundle = {
                    let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"].map { URL(fileURLWithPath: $0) }
                    let candidates = [override, Bundle.main.resourceURL, Bundle(for: Token.self).resourceURL, Bundle.main.bundleURL]
                    for candidate in candidates {
                        if let candidate, let bundle = Bundle(url: candidate.appendingPathComponent("\(name)Resources.bundle")) {
                            return bundle
                        }
                    }
                    fatalError("Missing \(name)Resources.bundle")
                }()
            }
            \(body)
            """.utf8).write(to: source)
            let compile = ["swiftc", "-parse-as-library", "-c", "-module-name", name, "-target",
                NativePreviewPlatform.macOS.triple, source.path, "-o", object.path]
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + compile)
            let fileList = root.appendingPathComponent(name + ".LinkFileList")
            try (object.path + "\n").write(to: fileList, atomically: true, encoding: .utf8)
            let link: [String]
            if framework {
                let resources = output.deletingLastPathComponent().appendingPathComponent("Resources")
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lynnswap.DynamicSupport",
                    "CFBundleExecutable": "Support", "CFBundlePackageType": "FMWK"], format: .binary, options: 0)
                    .write(to: resources.appendingPathComponent("Info.plist"))
                let framework = output.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
                try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Support").path, withDestinationPath: "Versions/Current/Support")
                try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
                link = dynamic
                    ? ["swiftc", "-emit-library", "-target", NativePreviewPlatform.macOS.triple, object.path, privateSupport.path,
                        "-Xlinker", "-install_name", "-Xlinker", "@rpath/Support.framework/Versions/A/Support", "-o", output.path]
                    : ["libtool", "-static", "-filelist", fileList.path, "-o", output.path]
            } else {
                link = ["clang", "-r", "-nostdlib", "-target", NativePreviewPlatform.macOS.triple,
                    "-filelist", fileList.path, "-o", output.path]
            }
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + link)
            targets.append(NativePreviewBuild.Target(moduleName: name, buildableName: name, sdkRoot: "macosx",
                sdkVariant: nil, architecture: "arm64", linkCommandLine: link, linkerWorkingDirectory: root.path,
                objectFiles: [object], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false,
                compileCommandLine: compile, isDynamicPackageProduct: dynamic))
            let resource = nativeProducts.appendingPathComponent(name + "Resources.bundle")
            let resources = resource.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lynnswap." + name + ".resources",
                "CFBundlePackageType": "BNDL"], format: .binary, options: 0).write(to: resource.appendingPathComponent("Contents/Info.plist"))
            try Data((name + " resource").utf8).write(to: resources.appendingPathComponent("Marker.txt"))
            resourceURLs.append(resource)
        }
        if kind == .staticFrameworkDependency {
            targets[1].dependencies = [NativePreviewBuild.Target(moduleName: nil, buildableName: "PrivateSupport", sdkRoot: "macosx",
                sdkVariant: nil, architecture: "arm64", linkCommandLine: ["clang", "-dynamiclib", "-o", privateSupport.path],
                linkerWorkingDirectory: root.path, objectFiles: [], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)]
        }
        targets[0].dependencies = [targets[1]]
        targets[0].resourceURLs = resourceURLs
        var roots = kind == .dynamicDependency || kind == .staticFrameworkDependency ? targets : [targets[0]]
        if kind == .dynamicSource {
            let output = nativeProducts.appendingPathComponent("PackageFrameworks/Source.framework/Source")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceObject = try #require(targets[0].outputURL)
            let support = try #require(targets[1].outputURL)
            let link = ["swiftc", "-emit-library", "-target", NativePreviewPlatform.macOS.triple,
                sourceObject.path, support.path, "-Xlinker", "-install_name", "-Xlinker", "@rpath/Source.framework/Source", "-o", output.path]
            try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx"] + link)
            let sourceProduct = NativePreviewBuild.Target(moduleName: "Source", buildableName: "Source.framework", sdkRoot: "macosx",
                sdkVariant: nil, architecture: "arm64", linkCommandLine: link, linkerWorkingDirectory: root.path,
                objectFiles: [sourceObject], sourceFiles: [], debugDylibEnabled: false, isRunnable: false,
                isDynamicPackageProduct: true, dependencies: targets, resourceURLs: resourceURLs)
            roots = [sourceProduct]
            targets.append(sourceProduct)
        }
        roots[0].containsPreviewSource = true
        let source = root.appendingPathComponent("Source.swift")
        let selection = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .macOS)
        #expect(selection.source.outputURL == selection.host.outputURL)
        let originalFiles = try targets.map { try #require($0.outputURL) } + (frameworkSupport ? [privateSupport] : [])
        let original = try originalFiles.map { try Data(contentsOf: $0) }
        let helper = root.appendingPathComponent("Helper")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loader = root.appendingPathComponent("Loader.m")
        try Data("""
        #import <Foundation/Foundation.h>
        #import <objc/runtime.h>
        #include <dlfcn.h>
        #include <stdio.h>
        @interface NSObject (ModuleProbe)
        + (NSBundle *)moduleBundle;
        @end
        int main(int argc, char **argv) {
            @autoreleasepool {
                for (int i = 1; i < argc; i++) {
                    if (!dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL)) { fputs(dlerror(), stderr); return 1; }
                }
                int (*value)(void) = dlsym(RTLD_DEFAULT, "source_value");
                if (!value) { fputs(dlerror(), stderr); return 1; }
                NSMutableDictionary *result = [@{@"value": @(value()), @"main": NSBundle.mainBundle.bundleIdentifier,
                    @"mainName": NSBundle.mainBundle.bundleURL.lastPathComponent} mutableCopy];
                for (NSString *name in @[@"Source", @"Support"]) {
                    Class token = NSClassFromString([NSString stringWithFormat:@"Hostless%@Token", name]);
                    if (!token) return 2;
                    NSBundle *owner = [NSBundle bundleForClass:token];
                    NSBundle *module = [(id)token moduleBundle];
                    NSString *marker = [NSString stringWithContentsOfURL:[module URLForResource:@"Marker" withExtension:@"txt"]
                        encoding:NSUTF8StringEncoding error:nil];
                    result[name] = @{@"owner": owner.bundleURL.path, @"identifier": owner.bundleIdentifier ?: NSNull.null,
                        @"module": module.bundleIdentifier ?: NSNull.null, @"marker": marker ?: NSNull.null,
                        @"image": @(class_getImageName(token))};
                }
                NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                fwrite(data.bytes, 1, data.length, stdout);
                return 0;
            }
        }
        """.utf8).write(to: loader)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", "-fobjc-arc",
            "-framework", "Foundation", loader.path, "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        let agent = try previewAgent(in: root, helper: helper)
        let app = root.appendingPathComponent("Staged").appendingPathComponent(agent.lastPathComponent)
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: false)
        let products = try NativePreviewCorrection.prepareApp(product: agent, sourceProduct: try #require(selection.source.outputURL),
            helper: helper, app: app, platform: .macOS, staticProduct: true, resourceURLs: selection.source.resourceURLs)
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let images = try await NativePreviewCorrection.linkStaticProducts(for: roots, in: app, products: products,
            platform: .macOS, process: process)
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: roots, targets: targets, platform: .macOS,
            in: products, agentApp: app, linkedImages: images)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: products)
        let libraries = dependencies.rootLibraries.map { products.appendingPathComponent($0) }
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies, in: products, process: process)
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let executable = NativePreviewPlatform.macOS.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer")
        let text = try await process.run(executable.path, libraries.map(\.path), environment: ["PACKAGE_RESOURCE_BUNDLE_PATH": products.path])
        let result = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(result["value"] as? Int == 10)
        #expect(result["main"] as? String == Bundle(url: agent)?.bundleIdentifier)
        #expect(result["mainName"] as? String == agent.lastPathComponent)
        for name in ["Source", "Support"] {
            let record = try #require(result[name] as? [String: Any])
            let agentOwned = (kind == .dynamicSource && name == "Source") || (kind == .dynamicDependency && name == "Support")
            let loadedImage = URL(filePath: try #require(record["image"] as? String)).resolvingSymlinksInPath()
            if agentOwned {
                #expect(record["owner"] as? String == app.resolvingSymlinksInPath().path)
                #expect(record["identifier"] as? String == Bundle(url: agent)?.bundleIdentifier)
                #expect(loadedImage.deletingLastPathComponent() == executable.deletingLastPathComponent().resolvingSymlinksInPath())
                #expect(libraries.map { $0.resolvingSymlinksInPath() }.contains(loadedImage))
            } else if kind == .dynamicSource {
                #expect(record["identifier"] as? String == "dev.lynnswap.DynamicSupport")
                #expect(URL(filePath: try #require(record["owner"] as? String)).lastPathComponent == "Support.framework")
            } else {
                #expect(record["owner"] as? String == products.resolvingSymlinksInPath().path)
                #expect(record["identifier"] is NSNull)
                let owner = kind == .staticFrameworkDependency && name == "Support" ? targets[1] : selection.source
                let ownerOutput = try #require(owner.outputURL).resolvingSymlinksInPath()
                #expect(loadedImage == images[ownerOutput]?.url.resolvingSymlinksInPath())
            }
            #expect(record["module"] as? String == "dev.lynnswap." + name + ".resources")
            #expect(record["marker"] as? String == name + " resource")
        }
        let sourceRecord = try #require(result["Source"] as? [String: Any])
        let sourceImage = URL(filePath: try #require(sourceRecord["image"] as? String)).resolvingSymlinksInPath()
        #expect(try NativePreviewBinary.dynamicLibrary(at: sourceImage)?.dependencies.contains(where: { $0.contains(privateSupport.lastPathComponent) }) == false)
        if kind == .staticFrameworkDependency {
            let supportRecord = try #require(result["Support"] as? [String: Any])
            let supportImage = URL(filePath: try #require(supportRecord["image"] as? String)).resolvingSymlinksInPath()
            #expect(sourceImage != supportImage)
            #expect(libraries.map { $0.resolvingSymlinksInPath() } == [sourceImage, supportImage])
            let sourceSymbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-jU", sourceImage.path]).split(whereSeparator: \.isNewline)
            let supportSymbols = try previewBinaryOutput("/usr/bin/xcrun", ["nm", "-jU", supportImage.path]).split(whereSeparator: \.isNewline)
            #expect(sourceSymbols.contains("_source_value"))
            #expect(!sourceSymbols.contains("_support_value"))
            #expect(supportSymbols.contains("_support_value"))
            #expect(!supportSymbols.contains("_source_value"))
            #expect(try NativePreviewBinary.dynamicLibrary(at: sourceImage)?.dependencies.contains(where: { $0.contains(supportImage.lastPathComponent) }) == true)
            #expect(try NativePreviewBinary.dynamicLibrary(at: supportImage)?.dependencies.contains(where: { $0.contains(privateSupport.lastPathComponent) }) == true)
        }
        #expect(try originalFiles.map { try Data(contentsOf: $0) } == original)
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
        let products = root.appendingPathComponent("Staged/Products/Debug")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: framework, to: products.appendingPathComponent(framework.lastPathComponent))
        let developer = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developer)), artifacts: root)
        let image = try await NativePreviewCorrection.linkStaticProduct(target, in: root.appendingPathComponent("Staged/Preview.app"),
            products: products, platform: platform, process: process).url
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

        let agent = try previewAgent(in: root, helper: helper, platform: platform)
        try NativePreviewCorrection.prepareApp(product: agent, sourceProduct: framework, helper: helper, app: app, platform: platform)

        let staged = platform.frameworksDirectory(in: app).appendingPathComponent("FixtureKit.framework")
        let bundle = try #require(Bundle(url: staged))
        #expect(bundle.bundleIdentifier == identifier)
        let marker = try #require(bundle.url(forResource: "Marker", withExtension: "txt"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "framework resource")
        #expect(Bundle(url: app)?.bundleIdentifier == Bundle(url: agent)?.bundleIdentifier)
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
        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: [sourceTarget], targets: targets, platform: .macOS,
            in: NativePreviewPlatform.macOS.frameworksDirectory(in: app), sourceProduct: source.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loaderSource = root.appendingPathComponent("Loader.c")
        try Data("#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (dlopen(argv[1], RTLD_NOW)) return 0; fputs(dlerror(), stderr); return 1; }\n".utf8)
            .write(to: loaderSource)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", loaderSource.path,
            "-Wl,-rpath,@executable_path/../Frameworks", "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        if prebuilt {
            try previewBinaryOutput(helper.appendingPathComponent("XcodeMCPPreviewRenderer").path, [source.path])
        }
        let agent = try previewAgent(in: root, helper: helper)
        try NativePreviewCorrection.prepareApp(product: agent, sourceProduct: source.deletingLastPathComponent(), helper: helper, app: app,
            platform: .macOS)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: NativePreviewPlatform.macOS.frameworksDirectory(in: app))
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
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies,
            in: NativePreviewPlatform.macOS.frameworksDirectory(in: app), process: process)
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
        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: [target], targets: [target], platform: .macOS,
            in: NativePreviewPlatform.macOS.frameworksDirectory(in: app), sourceProduct: framework)
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loaderSource = root.appendingPathComponent("Loader.c")
        try Data("#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (dlopen(argv[1], RTLD_NOW)) return 0; fputs(dlerror(), stderr); return 1; }\n".utf8)
            .write(to: loaderSource)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", loaderSource.path,
            "-Wl,-rpath,@executable_path/../Frameworks",
            "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])

        try previewBinaryOutput(helper.appendingPathComponent("XcodeMCPPreviewRenderer").path, [source.path])

        let agent = try previewAgent(in: root, helper: helper)
        try NativePreviewCorrection.prepareApp(product: agent, sourceProduct: framework, helper: helper, app: app, platform: .macOS)
        try NativePreviewCorrection.copyFrameworkDependencies(dependencies, into: NativePreviewPlatform.macOS.frameworksDirectory(in: app))

        let developerDirectory = try previewBinaryOutput("/usr/bin/xcode-select", ["-p"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: URL(filePath: developerDirectory)), artifacts: root)
        try await NativePreviewCorrection.relocateFrameworkDependencies(dependencies,
            in: NativePreviewPlatform.macOS.frameworksDirectory(in: app), process: process)

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
        let stream = try await correction.execute(inputType: PreviewInput.self, input: input, artifactsRoot: root) {
            AsyncStream { continuation in
                continuation.yield(nativeEvent)
                continuation.finish()
            }
        }
        var events: [Data] = []
        for await event in stream { events.append(event) }
        #expect(events == [nativeEvent])
    }

    private func previewAgent(in root: URL, helper: URL, platform: NativePreviewPlatform = .macOS) throws -> URL {
        let agent = root.appendingPathComponent("PreviewAgent.app")
        try FileManager.default.createDirectory(at: platform.resourcesDirectory(in: agent), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: platform.executableDirectory(in: agent), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "dev.lynnswap.PreviewAgent", "CFBundleName": "PreviewAgent",
            "CFBundleExecutable": "Original", "CFBundlePackageType": "APPL"]
        if platform == .iOS { info["UIDeviceFamily"] = [1, 2] }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: platform.infoURL(in: agent))
        try FileManager.default.copyItem(at: helper.appendingPathComponent("XcodeMCPPreviewRenderer"),
            to: platform.executableDirectory(in: agent).appendingPathComponent("Original"))
        return agent
    }
}

private struct PreviewInput: Codable {
    let temporaryArtifactsPath: String
    let sourceFilePath: String
}
