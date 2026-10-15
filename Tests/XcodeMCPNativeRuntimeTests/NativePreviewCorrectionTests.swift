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
            try NativePreviewCorrection.selectTarget(targets, source: source, platform: .iOS,
                preferredArchitecture: "x86_64")
        }
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

    @Test(arguments: ["arm64", "x86_64"])
    func universalMacHostUsesDestinationArchitecture(architecture: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("ContentView.swift")
        let output = root.appendingPathComponent("Fixture.app/Contents/MacOS/Fixture.debug.dylib")
        let targets = ["arm64", "x86_64"].map { architecture in
            NativePreviewBuild.Target(moduleName: "Fixture", buildableName: "Fixture.app",
                sdkRoot: "macosx", sdkVariant: nil, architecture: architecture,
                linkCommandLine: ["-o", output.path], linkerWorkingDirectory: nil,
                objectFiles: [], sourceFiles: [source], debugDylibEnabled: true, isRunnable: true)
        }
        let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .macOS,
            preferredArchitecture: architecture)
        #expect(selected.source.architecture == architecture)
        #expect(selected.host.architecture == architecture)
    }

    @Test(arguments: [true, false])
    func sharedLibraryDestinationArchitecturePrecedesHostSelection(hasCompatibleHost: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("PackageView.swift")
        var targets = ["arm64", "x86_64"].flatMap { architecture in
            let product = root.appendingPathComponent("\(architecture)/FixturePackage.o")
            return [NativePreviewBuild.Target(moduleName: "FixturePackage", buildableName: "FixturePackage.o",
                sdkRoot: "macosx", sdkVariant: nil, architecture: architecture,
                linkCommandLine: ["-o", product.path], linkerWorkingDirectory: nil, objectFiles: [],
                sourceFiles: [source], debugDylibEnabled: false, isRunnable: false),
                NativePreviewBuild.Target(moduleName: architecture, buildableName: "\(architecture).app",
                    sdkRoot: "macosx", sdkVariant: nil, architecture: architecture,
                    linkCommandLine: ["-o", root.appendingPathComponent("\(architecture).app/Contents/MacOS/Host.debug.dylib").path, product.path],
                    linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true,
                    isRunnable: architecture == "arm64")]
        }
        if hasCompatibleHost {
            let selected = try NativePreviewCorrection.selectTarget(targets, source: source, platform: .macOS,
                preferredArchitecture: "x86_64")
            #expect(selected.source.architecture == "x86_64")
            #expect(selected.host.architecture == "x86_64")
        } else {
            targets.removeAll { $0.buildableName == "x86_64.app" }
            #expect(throws: NativePipelineRequired.self) {
                try NativePreviewCorrection.selectTarget(targets, source: source, platform: .macOS,
                    preferredArchitecture: "x86_64")
            }
        }
    }

    @Test(arguments: [NativePreviewPlatform.macOS, .catalyst])
    func desktopSharedLibraryUsesSameArchitectureHost(platform: NativePreviewPlatform) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("PackageView.swift")
        let product = root.appendingPathComponent("FixturePackage.o")
        let hosts = ["arm64", "x86_64"].map { architecture in
            NativePreviewBuild.Target(moduleName: architecture, buildableName: "FixtureHost.app",
                sdkRoot: "macosx", sdkVariant: platform == .catalyst ? "iosmac" : nil, architecture: architecture,
                linkCommandLine: ["-o", root.appendingPathComponent("\(architecture).app/Contents/MacOS/FixtureHost.debug.dylib").path, product.path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: true, isRunnable: true)
        }
        let sourceTarget = NativePreviewBuild.Target(moduleName: "FixturePackage", buildableName: "FixturePackage.o",
            sdkRoot: "macosx", sdkVariant: platform == .catalyst ? "iosmac" : nil, architecture: "x86_64", linkCommandLine: ["-o", product.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        let selected = try NativePreviewCorrection.selectTarget(hosts + [sourceTarget], source: source, platform: platform,
            preferredArchitecture: "arm64")
        #expect(selected.source.architecture == "x86_64")
        #expect(selected.host.architecture == "x86_64")
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

    @Test(arguments: [NativePreviewPlatform.iOS, .macOS])
    func standaloneStaticFrameworkRequiresNativePipeline(platform: NativePreviewPlatform) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("FrameworkView.swift")
        let binary = root.appendingPathComponent("FixtureKit.framework/FixtureKit")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("!<arch>\n".utf8).write(to: binary)
        let target = NativePreviewBuild.Target(moduleName: "FixtureKit", buildableName: "FixtureKit.framework",
            sdkRoot: platform.rawValue, sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", binary.path],
            linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [source], debugDylibEnabled: false, isRunnable: false)
        #expect(throws: NativePipelineRequired.self) {
            try NativePreviewCorrection.selectTarget([target], source: source, platform: platform)
        }
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
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "FixtureKit", "CFBundleName": "FixtureKit", "CFBundlePackageType": "FMWK"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("Info.plist"))
        try Data("framework resource".utf8).write(to: resources.appendingPathComponent("Marker.txt"))
        try Data("renderer".utf8).write(to: helper.appendingPathComponent("XcodeMCPPreviewRenderer"))

        try NativePreviewCorrection.prepareApp(product: framework, helper: helper, app: app, platform: platform)

        let staged = platform.frameworksDirectory(in: app).appendingPathComponent("FixtureKit.framework")
        let bundle = try #require(Bundle(url: staged))
        #expect(bundle.bundleIdentifier == identifier)
        let marker = try #require(bundle.url(forResource: "Marker", withExtension: "txt"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "framework resource")
        #expect(Bundle(url: app)?.bundleIdentifier != identifier)
        #expect(Bundle(url: app)?.url(forResource: "Marker", withExtension: "txt") == nil)
        #expect(try Data(contentsOf: platform.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer")) == Data("renderer".utf8))
        let libraries = try NativePreviewCorrection.registryLibraries(in: app, previewLibraries: [])
        let paths = try NativePreviewCorrection.libraryPaths(in: app, previewLibraries: [], registryLibraries: libraries, sourceOutput: binary, architecture: "arm64")
        #expect(paths == [String(staged.appendingPathComponent(relativeBinary).path.dropFirst(app.path.count + 1))])
        #expect(try String(contentsOf: resources.appendingPathComponent("Marker.txt"), encoding: .utf8) == "framework resource")
    }

    @Test func standaloneFrameworkStagesItsTransitiveBuiltDependencies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("Products")
        let source = products.appendingPathComponent("Feature.framework/Feature")
        let dependency = products.appendingPathComponent("Dependency.framework/Dependency")
        let library = products.appendingPathComponent("libSupport.dylib")
        let unrelated = products.appendingPathComponent("libUnrelated.dylib")
        for binary in [source, dependency] {
            let resources = binary.deletingLastPathComponent().appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "dev.lynnswap." + binary.lastPathComponent,
                        "CFBundleExecutable": binary.lastPathComponent, "CFBundlePackageType": "FMWK"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: resources.appendingPathComponent("Info.plist"))
        }
        let marker = dependency.deletingLastPathComponent().appendingPathComponent("Resources/Marker.txt")
        try Data("dependency resource".utf8).write(to: marker)
        try compilePreviewLibrary(at: library, platform: .macOS, installName: "@rpath/libSupport.dylib")
        try compilePreviewLibrary(at: unrelated, platform: .macOS, installName: "@rpath/libUnrelated.dylib")
        try compilePreviewLibrary(at: dependency, platform: .macOS,
            installName: "@rpath/Dependency.framework/Dependency", libraries: [library])
        try compilePreviewLibrary(at: source, platform: .macOS,
            installName: "@rpath/Feature.framework/Feature", libraries: [dependency])
        for binary in [source, dependency, library] {
            try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        }
        func target(_ binary: URL, sdk: String = "macosx") -> NativePreviewBuild.Target {
            NativePreviewBuild.Target(moduleName: binary.lastPathComponent, buildableName: binary.lastPathComponent,
                sdkRoot: sdk, sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", binary.path],
                linkerWorkingDirectory: nil, objectFiles: [], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)
        }
        let sourceTarget = target(source)
        let dependencies = try NativePreviewCorrection.frameworkDependencies(for: sourceTarget,
            targets: [sourceTarget, target(dependency), target(library), target(unrelated)], platform: .macOS)

        let helper = root.appendingPathComponent("Helper")
        let app = root.appendingPathComponent("Preview.app")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let loaderSource = root.appendingPathComponent("Loader.c")
        try Data("#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (dlopen(argv[1], RTLD_NOW)) return 0; fputs(dlerror(), stderr); return 1; }\n".utf8)
            .write(to: loaderSource)
        try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", "arm64", loaderSource.path,
            "-Wl,-rpath,@executable_path/../Frameworks", "-o", helper.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        try NativePreviewCorrection.prepareApp(product: source.deletingLastPathComponent(), helper: helper, app: app,
            platform: .macOS, dependencies: dependencies)
        // Loading succeeds entirely from staging after the original products move.
        try FileManager.default.moveItem(at: products, to: root.appendingPathComponent("OriginalProducts"))
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        let stagedDependency = try #require(Bundle(url: frameworks.appendingPathComponent("Dependency.framework")))
        let stagedMarker = try #require(stagedDependency.url(forResource: "Marker", withExtension: "txt"))
        #expect(try String(contentsOf: stagedMarker, encoding: .utf8) == "dependency resource")
        #expect(!FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(unrelated.lastPathComponent).path))
        try previewBinaryOutput(app.appendingPathComponent("Contents/MacOS/XcodeMCPPreviewRenderer").path,
            [frameworks.appendingPathComponent("Feature.framework/Feature").path])
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
        #expect(try NativePreviewCorrection.containingApp(for: output, targets: hosts, architecture: "arm64")?.path
            == root.appendingPathComponent("Matching.app").path)
        #expect(try NativePreviewCorrection.containingApp(for: output, targets: [hosts[0]], architecture: "arm64") == nil)
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
            "CFBundlePackageType": "XPC!", "MinimumOSVersion": "27.0",
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
