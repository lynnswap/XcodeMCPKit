import Foundation
import NIOCore
import NIOConcurrencyHelpers
import Testing
import XcodeMCPCore
import XcodeMCPProxyTestSupport
@testable import XcodeMCPDocumentationSearch

@Suite(.serialized, .asyncTestCleanup)
struct DocumentationSearchBackendTests {
    @Test func liveDocumentationSearchServiceRepairerPrefersHostCompatibleAssetOverExactXcodeVersion()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950001
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5-old-os",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5-current-os",
            xcodeVersion: "26.5",
            osVersion: "26.6",
            documentationRelease: 900340
        )
        let writtenValues = NIOLockedValueBox<[String]>([])
        let repairer = InstalledDocumentationSearchRepairer(
            assetRoot: root,
            currentOSVersion: { "26.6.1" },
            readConfigURLOverride: { nil },
            writeConfigURLOverride: { value in
                writtenValues.withLockedValue { $0.append(value) }
                return true
            }
        )

        let result = await repairer.repair(
            for: DocumentationSearchInstallation(appPath: "/fixture/Xcode.app", xcodeVersion: "27.0")
        )

        guard case .repaired(let report) = result else {
            Issue.record("expected repaired result, got \(result)")
            return
        }
        #expect(report.xcodeVersion == "26.5")
        #expect(report.osVersion == "26.6")
        #expect(report.documentationRelease == 900340)
        #expect(report.changedDefault)
        #expect(report.configURL.contains("xcode-26-5-current-os.asset/AssetData/config.json"))
        #expect(writtenValues.withLockedValue { $0 } == [report.configURL])
    }

    @Test func liveDocumentationSearchServiceRepairerSkipsWithoutHostCompatibleAsset()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950001
        )
        let writtenValues = NIOLockedValueBox<[String]>([])
        let repairer = InstalledDocumentationSearchRepairer(
            assetRoot: root,
            currentOSVersion: { "26.6.1" },
            readConfigURLOverride: { nil },
            writeConfigURLOverride: { value in
                writtenValues.withLockedValue { $0.append(value) }
                return true
            }
        )

        let result = await repairer.repair(
            for: DocumentationSearchInstallation(appPath: "/fixture/Xcode.app", xcodeVersion: "27.0")
        )

        #expect(
            result == .skipped(
                "no_host_compatible_documentation_asset current_os=26.6.1"
            )
        )
        #expect(writtenValues.withLockedValue { $0 }.isEmpty)
    }

    @Test func documentationAssetLocatorExcludesAssetsNewerThanHostOS()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27-newer-os",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950001
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5-current-os",
            xcodeVersion: "26.5",
            osVersion: "26.6",
            documentationRelease: 900340
        )
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: root)

        let orderedAssets = DocumentationSearchAssetLocator
            .hostCompatibleAssetsOrderedByCompatibility(
                for: "27.0",
                currentOSVersion: "26.6.1",
                from: scan.assets
            )

        #expect(orderedAssets.map(\.xcodeVersion) == ["26.5"])
    }

    @Test func documentationAssetLocatorTreatsTrailingZeroXcodeVersionsAsExactMatch()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26",
            xcodeVersion: "26",
            osVersion: "26.0",
            documentationRelease: 900100
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-0-0",
            xcodeVersion: "26.0.0",
            osVersion: "26.0",
            documentationRelease: 900200
        )
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: root)

        let asset = try #require(
            DocumentationSearchAssetLocator.bestHostCompatibleAsset(
                for: "26.0",
                currentOSVersion: "26.0",
                from: scan.assets
            )
        )

        #expect(asset.xcodeVersion == "26.0.0")
        #expect(asset.documentationRelease == 900200)
    }

    @Test func documentationAssetLocatorSelectsLatestInstalledAsset()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 999999
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27-old-release",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950000
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27-new-release",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950001
        )
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: root)

        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))

        #expect(asset.xcodeVersion == "27.0")
        #expect(asset.documentationRelease == 950001)
        #expect(asset.assetURL.path.contains("xcode-27-new-release.asset"))
    }

    @Test func documentationSearchActionInvokerPassesLatestAssetWithActionDefaults()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let processRunner = DocumentationSearchActionProcessRecorder()
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: processRunner
        )

        _ = try await invoker.invoke(
            DocumentationSearchActionInvocation(
                installation: target,
                asset: asset,
                query: "NavigationSplitView",
                frameworks: ["SwiftUI"],
                limit: nil
            ),
            timeout: .seconds(1)
        )
        _ = try await invoker.invoke(
            DocumentationSearchActionInvocation(
                installation: target,
                asset: asset,
                query: "NavigationSplitView",
                frameworks: ["SwiftUI"],
                limit: nil
            ),
            timeout: .seconds(1)
        )

        let requests = await processRunner.recordedRequests()
        let binPathRequests = requests.filter { $0.label == "DocumentationSearchAction.bin-path" }
        #expect(binPathRequests.count == 1)
        let binPathRequest = try #require(binPathRequests.first)
        #expect(binPathRequest.arguments.contains("--show-bin-path"))
        #expect(binPathRequest.arguments.contains("DEVELOPER_DIR=\(target.developerDir)"))
        let buildRequests = requests.filter { $0.label == "DocumentationSearchAction.build" }
        #expect(buildRequests.count == 1)
        let buildRequest = try #require(buildRequests.first)
        #expect(buildRequest.arguments.contains("DEVELOPER_DIR=\(target.developerDir)"))
        #expect(buildRequest.arguments.contains(
            URL(fileURLWithPath: target.appPath)
                .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
                .path
        ))
        #expect(buildRequest.arguments.contains("build"))
        #expect(processArgumentValue(after: "--configuration", in: buildRequest.arguments) == "release")
        #expect(
            processArgumentValue(after: "--product", in: buildRequest.arguments)
                == "documentation-search-action-helper"
        )
        #expect(processArgumentValue(after: "--sdk", in: buildRequest.arguments) == "/tmp/MacOSX.sdk")
        let packagePath = try #require(processArgumentValue(after: "--package-path", in: buildRequest.arguments))
        #expect(processArgumentValue(after: "--package-path", in: binPathRequest.arguments) == packagePath)
        let packageRoot = URL(fileURLWithPath: packagePath, isDirectory: true)
        #expect(packageRoot.deletingLastPathComponent().path == cacheRoot.path)
        #expect(packageRoot.lastPathComponent.hasPrefix("runtime-"))
        #expect(packageRoot.lastPathComponent.contains("-sources-"))
        #expect(
            processArgumentValue(after: "--scratch-path", in: buildRequest.arguments)
                == packageRoot.appendingPathComponent(".build", isDirectory: true).path
        )
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains("documentation-search-action-helper"))
        #expect(FileManager.default.fileExists(
            atPath: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("DocumentationSearchActionHelper", isDirectory: true)
                .appendingPathComponent("main.swift")
                .path
        ))

        let helperRequest = try #require(
            requests.last { $0.label == "DocumentationSearchAction" }
        )
        let input = try #require(helperRequest.input)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(input.utf8), options: []) as? [String: Any]
        )
        #expect(object["query"] as? String == "NavigationSplitView")
        #expect(object["frameworks"] as? [String] == ["SwiftUI"])
        #expect(object["configURL"] as? String == asset.configURL.path)
        #expect(object["maxResults"] as? Int == 20)
        #expect(object["scoreThreshold"] as? Double == 0.4)

        let oneSecond = Int64(1_000_000_000)
        let sdkRequest = try #require(requests.first { $0.label == "DocumentationSearchAction.sdk" })
        let sdkTimeout = try #require(sdkRequest.timeoutNanoseconds)
        #expect(sdkTimeout > 0 && sdkTimeout <= oneSecond)
        let binPathTimeout = try #require(binPathRequest.timeoutNanoseconds)
        let buildTimeout = try #require(buildRequest.timeoutNanoseconds)
        #expect(binPathTimeout > oneSecond)
        #expect(buildTimeout > oneSecond)
        #expect(buildTimeout <= binPathTimeout)
        let helperTimeout = try #require(helperRequest.timeoutNanoseconds)
        #expect(helperTimeout > 0 && helperTimeout <= oneSecond)
    }

    @Test func documentationSearchActionInvokerCoalescesConcurrentHelperPreparation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let buildStarted = TestSignal()
        let releaseBuild = TestSignal()
        let processRunner = BlockingDocumentationSearchActionProcessRunner(
            buildStarted: buildStarted,
            releaseBuild: releaseBuild
        )
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: processRunner
        )
        let invocation = DocumentationSearchActionInvocation(
                installation: target,
            asset: asset,
            query: "NavigationSplitView",
            frameworks: ["SwiftUI"],
            limit: nil
        )

        let first = Task {
            try await invoker.invoke(invocation, timeout: .seconds(5))
        }
        defer {
            releaseBuild.signal()
            first.cancel()
        }
        try await buildStarted.wait(description: "waiting for first DocumentationSearchAction helper build")

        let second = Task {
            try await invoker.invoke(invocation, timeout: .seconds(5))
        }
        defer {
            second.cancel()
        }
        try await waitWithTimeout("waiting for second DocumentationSearchAction sdk lookup") {
            while await processRunner.recordedRequests().filter({ $0.label == "DocumentationSearchAction.sdk" }).count < 2 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        releaseBuild.signal()
        _ = try await first.value
        _ = try await second.value

        let requests = await processRunner.recordedRequests()
        #expect(requests.filter { $0.label == "DocumentationSearchAction.bin-path" }.count == 1)
        #expect(requests.filter { $0.label == "DocumentationSearchAction.build" }.count == 1)
        #expect(requests.filter { $0.label == "DocumentationSearchAction" }.count == 2)
    }

    @Test func documentationSearchActionInvokerKeepsSharedHelperPreparationAfterShortWaiterTimeout()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let buildStarted = TestSignal()
        let releaseBuild = TestSignal()
        let processRunner = BlockingDocumentationSearchActionProcessRunner(
            buildStarted: buildStarted,
            releaseBuild: releaseBuild
        )
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: processRunner
        )
        let invocation = DocumentationSearchActionInvocation(
                installation: target,
            asset: asset,
            query: "NavigationSplitView",
            frameworks: ["SwiftUI"],
            limit: nil
        )

        let shortWaiter = Task {
            try await invoker.invoke(invocation, timeout: .milliseconds(50))
        }
        defer {
            releaseBuild.signal()
            shortWaiter.cancel()
        }
        try await buildStarted.wait(description: "waiting for DocumentationSearchAction helper build")
        await #expect(throws: TimeoutError.self) {
            try await shortWaiter.value
        }

        let longWaiter = Task {
            try await invoker.invoke(invocation, timeout: .seconds(5))
        }
        defer {
            longWaiter.cancel()
        }
        try await waitWithTimeout("waiting for second DocumentationSearchAction sdk lookup") {
            while await processRunner.recordedRequests().filter({ $0.label == "DocumentationSearchAction.sdk" }).count < 2 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        releaseBuild.signal()
        _ = try await longWaiter.value

        let requests = await processRunner.recordedRequests()
        #expect(requests.filter { $0.label == "DocumentationSearchAction.bin-path" }.count == 1)
        let buildRequests = requests.filter { $0.label == "DocumentationSearchAction.build" }
        #expect(buildRequests.count == 1)
        let buildRequest = try #require(buildRequests.first)
        let buildTimeout = try #require(buildRequest.timeoutNanoseconds)
        #expect(buildTimeout > 1_000_000_000)
        #expect(requests.filter { $0.label == "DocumentationSearchAction" }.count == 1)
    }

    @Test func documentationSearchActionInvokerMapsProcessTimeoutToRequestTimeout()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: DocumentationSearchActionTimeoutProcessRunner()
        )

        await #expect(throws: TimeoutError.self) {
            try await invoker.invoke(
                DocumentationSearchActionInvocation(
                installation: target,
                    asset: asset,
                    query: "NavigationSplitView",
                    frameworks: ["SwiftUI"],
                    limit: nil
                ),
                timeout: .seconds(1)
            )
        }
    }

}

private actor DocumentationSearchActionProcessRecorder: ProcessRunning {
    private var requests: [ProcessRequest] = []

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        requests.append(request)
        switch request.label {
        case "DocumentationSearchAction.sdk":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "/tmp/MacOSX.sdk\n",
                stderr: ""
            )
        case "DocumentationSearchAction.bin-path":
            guard let scratchPath = processArgumentValue(after: "--scratch-path", in: request.arguments) else {
                return ProcessOutput(
                    terminationStatus: 1,
                    stdout: "",
                    stderr: "missing scratch path"
                )
            }
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "\(scratchPath)/out/Products/Release\n",
                stderr: ""
            )
        case "DocumentationSearchAction.build":
            try createFakeDocumentationSearchActionHelperExecutable(for: request.arguments)
            return ProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        case "DocumentationSearchAction":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: #"{"documents":[]}"#,
                stderr: ""
            )
        default:
            return ProcessOutput(
                terminationStatus: 1,
                stdout: "",
                stderr: "unexpected process request: \(request.label)"
            )
        }
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }
}

private actor BlockingDocumentationSearchActionProcessRunner: ProcessRunning {
    private var requests: [ProcessRequest] = []
    private let buildStarted: TestSignal
    private let releaseBuild: TestSignal

    init(buildStarted: TestSignal, releaseBuild: TestSignal) {
        self.buildStarted = buildStarted
        self.releaseBuild = releaseBuild
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        requests.append(request)
        switch request.label {
        case "DocumentationSearchAction.sdk":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "/tmp/MacOSX.sdk\n",
                stderr: ""
            )
        case "DocumentationSearchAction.bin-path":
            guard let scratchPath = processArgumentValue(after: "--scratch-path", in: request.arguments) else {
                return ProcessOutput(
                    terminationStatus: 1,
                    stdout: "",
                    stderr: "missing scratch path"
                )
            }
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "\(scratchPath)/out/Products/Release\n",
                stderr: ""
            )
        case "DocumentationSearchAction.build":
            buildStarted.signal()
            try await releaseBuild.wait(description: "waiting to release DocumentationSearchAction helper build")
            try createFakeDocumentationSearchActionHelperExecutable(for: request.arguments)
            return ProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        case "DocumentationSearchAction":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: #"{"documents":[]}"#,
                stderr: ""
            )
        default:
            return ProcessOutput(
                terminationStatus: 1,
                stdout: "",
                stderr: "unexpected process request: \(request.label)"
            )
        }
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }
}

private struct DocumentationSearchActionTimeoutProcessRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        throw ProcessTimeoutError(label: request.label)
    }
}

private func processArgumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

private func createFakeDocumentationSearchActionHelperExecutable(for arguments: [String]) throws {
    guard let scratchPath = processArgumentValue(after: "--scratch-path", in: arguments) else {
        return
    }
    let helperURL = URL(fileURLWithPath: scratchPath, isDirectory: true)
        .appendingPathComponent("out", isDirectory: true)
        .appendingPathComponent("Products", isDirectory: true)
        .appendingPathComponent("Release", isDirectory: true)
        .appendingPathComponent("documentation-search-action-helper")
    try FileManager.default.createDirectory(
        at: helperURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: helperURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: helperURL.path
    )
}

private func makeFakeXcodeApp(root: URL) throws -> DocumentationSearchInstallation {
    let appURL = root.appendingPathComponent("Xcode.app", isDirectory: true)
    let swiftURL = appURL
        .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    let dvtFrameworkURL = appURL
        .appendingPathComponent("Contents/SharedFrameworks/DVTFoundation.framework/DVTFoundation")
    let chatFrameworkURL = appURL
        .appendingPathComponent("Contents/PlugIns/IDEIntelligenceChat.framework/IDEIntelligenceChat")
    let platformDeveloperLibraryURL = appURL
        .appendingPathComponent("Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", isDirectory: true)
    for fileURL in [swiftURL, dvtFrameworkURL, chatFrameworkURL] {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: fileURL)
    }
    try FileManager.default.createDirectory(
        at: appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: platformDeveloperLibraryURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: swiftURL.path
    )
    return DocumentationSearchInstallation(
        appPath: appURL.path,
        xcodeVersion: "27.0"
    )
}

private extension DocumentationSearchInstallation {
    var developerDir: String { URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Developer").path }
}
