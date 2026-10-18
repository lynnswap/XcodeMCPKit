import CoreGraphics
import Foundation
import ImageIO
import Testing
import XcodeMCPKit
import XcodeMCPKitTesting
@testable import XcodeMCPProxyToolVerifier

struct PreviewVerifierTests {
    @Test func nativeWindowSelectionMatchesTheOwnedProjectDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Owned Fixture.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let message = "* tabIdentifier: unrelated-window, workspacePath: \(root.appendingPathComponent("Other.xcodeproj").path)\n"
            + "* tabIdentifier: owned-window, workspacePath: \(project.path)\n"
        #expect(previewTabIdentifier(in: message, project: project) == "owned-window")
    }

    @Test func preparePhysicalChangesOnlyItsOwnedSourceAndRequestedConfiguration() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let definition = try #require(PreviewFixtureDefinition.load(in: repository).first { $0.id == "physical-bare" })
        let original = repository.appendingPathComponent("Fixtures/ProxyToolVerifierFixture")
        let before = try previewFileDigests(in: original)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try writePreviewJSON(["ProxyToolVerifierFixture": ["Debug": ["CODE_SIGNING_ALLOWED": "YES", "DEVELOPMENT_TEAM": "EXAMPLE"]]], to: settings)
        let output = root.appendingPathComponent("prepared")
        let prepared = try PreparedPreviewFixture.prepare(definition: definition, repository: repository, output: output,
            deviceName: "Verifier's \"Phone\"", buildSettings: settings)
        let source = try String(contentsOf: output.appendingPathComponent("Project/ProxyToolVerifierFixture/ContentView.swift"), encoding: .utf8)
        #expect(source.contains("PreviewDevice(rawValue: \(String(reflecting: "Verifier's \"Phone\"")))"))
        #expect(!source.contains("__PREVIEW_DEVICE_NAME__"))
        #expect(try previewFileDigests(in: original) == before)
        #expect(try previewFileDigests(in: output.appendingPathComponent("Project")) == prepared.files)
        let originalObjects = try projectObjects(original.appendingPathComponent(definition.project))
        let actualObjects = try projectObjects(output.appendingPathComponent("Project/" + definition.project))
        let changed = actualObjects.keys.filter { !NSDictionary(dictionary: actualObjects[$0] ?? [:]).isEqual(to: originalObjects[$0] ?? [:]) }
        #expect(changed.count == 1)
        let configuration = try #require(changed.first.flatMap { actualObjects[$0] })
        #expect(configuration["name"] as? String == "Debug")
        let values = try #require(configuration["buildSettings"] as? [String: Any])
        #expect(values["CODE_SIGNING_ALLOWED"] as? String == "YES")
        #expect(values["DEVELOPMENT_TEAM"] as? String == "EXAMPLE")
    }

    @Test(arguments: ["general", "hostless-package", "remote-package"])
    func failedSelectionStopsRenderingAndClosesOnlyTheOwnedWorkspace(fixtureID: String) async throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let definition = try #require(PreviewFixtureDefinition.load(in: repository).first { $0.id == fixtureID })
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared")
        _ = try PreparedPreviewFixture.prepare(definition: definition, repository: repository, output: prepared,
            deviceName: nil, buildSettings: nil)
        let projectRoot = prepared.appendingPathComponent("Project")
        let project = projectRoot.appendingPathComponent(definition.project)
        let runtime = XcodeMCPTestRuntime(tools: [
            previewTool("XcodeOpenWorkspace"), previewTool("XcodeSwitchScheme"),
            previewTool("XcodeSwitchRunDestination"), previewTool("XcodeCloseWorkspace"), previewTool("RenderPreview")
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace":
                let path = try #require(call.arguments["path"]?.stringValue)
                if fixtureID == "hostless-package" {
                    #expect(path == project.path)
                } else {
                    let workspace = URL(filePath: path)
                    #expect(workspace.deletingLastPathComponent().path == root.path)
                    let document = try XMLDocument(contentsOf: workspace.appendingPathComponent("contents.xcworkspacedata"))
                    let reference = try #require(try document.nodes(forXPath: "/Workspace/FileRef/@location").first?.stringValue)
                    #expect(reference == "absolute:" + project.path)
                }
                return previewResult(["workspaceIdentifier": "owned-workspace"])
            case "XcodeSwitchRunDestination": return previewResult(["success": false, "errorDescription": "Destination unavailable"])
            case "XcodeCloseWorkspace":
                #expect(call.arguments["workspaceIdentifier"] == "owned-workspace")
                return previewResult(["message": "closed"])
            case "RenderPreview": Issue.record("Rendered after failed selection")
            default: break
            }
            return previewResult(["success": true])
        }
        let client = try await runtime.makeClient()
        var runner = PreviewCaptureRunner(output: root, projectRoot: projectRoot, project: project,
            report: captureReport(backend: .headless))
        await runner.capture(client: client)
        await client.close()
        #expect(!runner.report.operationSucceeded)
        #expect(runner.report.workspaceClosed)
        #expect(runner.report.failure?.contains("Destination unavailable") == true)
        #expect(await runtime.recordedToolCalls().filter { $0.name == "XcodeCloseWorkspace" }.count == 1)
    }

    @Test(arguments: [false, true])
    func nativeCaptureWaitsForDestinationsBeforeSelecting(requestedDestinationExists: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Fixture.xcworkspace")
        let snapshot = root.appendingPathComponent("native.png")
        try writePNG(snapshot, red: 1)
        try "initial source".write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        let readiness = PreviewDestinationReadiness()
        let availableTitle = requestedDestinationExists ? "My Mac" : "Another Mac"
        let runtime = XcodeMCPTestRuntime(tools: [
            previewTool("XcodeListWindows"), previewTool("XcodeSwitchScheme"), previewTool("XcodeListRunDestinations"),
            previewTool("XcodeSwitchRunDestination"), previewTool("RenderPreview")
        ])
        await runtime.setToolHandler { call in
            if call.name != "XcodeListWindows" {
                #expect(call.arguments["tabIdentifier"] == "owned-window")
            }
            switch call.name {
            case "XcodeListWindows":
                return previewResult(["message": .string("* tabIdentifier: owned-window, workspacePath: \(project.path)")])
            case "XcodeListRunDestinations":
                let ready = await readiness.readDestinations()
                return previewResult([
                    "activeSchemeName": "Fixture",
                    "activeDestinationDisplayTitle": ready ? .string(availableTitle) : .null,
                    "totalDestinations": ready ? 1 : 0,
                    "destinations": ready ? [["displayTitle": .string(availableTitle)]] : [],
                ])
            case "XcodeSwitchRunDestination":
                guard await readiness.isReady else {
                    return previewResult(["success": false, "errorDescription": "Destinations are still loading"])
                }
                if !requestedDestinationExists {
                    return previewResult(["success": false, "errorDescription": "Requested destination unavailable"])
                }
            case "RenderPreview":
                return previewResult(["displayName": "Preview", "previewSnapshotPath": .string(snapshot.path)])
            default: break
            }
            return previewResult(["success": true])
        }
        let client = try await runtime.makeClient()
        var runner = PreviewCaptureRunner(output: root, projectRoot: root, project: project,
            report: captureReport(backend: .native))
        await runner.capture(client: client)
        await client.close()
        #expect(runner.report.operationSucceeded == requestedDestinationExists)
        let calls = await runtime.recordedToolCalls()
        #expect(calls.filter { $0.name == "XcodeSwitchRunDestination" }.count == 1)
        if requestedDestinationExists {
            #expect(runner.report.failure == nil)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("preview.png").path))
        } else {
            #expect(runner.report.failure?.contains("Requested destination unavailable") == true)
            #expect(!calls.contains { $0.name == "RenderPreview" })
        }
    }

    @Test(arguments: [false, true])
    func sequenceCapturesRetainEachImageAndStopAfterAFailedEdit(editSucceeds: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("View.swift")
        try "initial source".write(to: source, atomically: true, encoding: .utf8)
        let initial = root.appendingPathComponent("initial.png")
        let edited = root.appendingPathComponent("edited.png")
        try writePNG(initial, red: 1)
        try writePNG(edited, red: 0)
        let runtime = XcodeMCPTestRuntime(tools: [
            previewTool("XcodeOpenWorkspace"), previewTool("XcodeSwitchScheme"), previewTool("XcodeListRunDestinations"),
            previewTool("XcodeSwitchRunDestination"), previewTool("RenderPreview"), previewTool("XcodeUpdate"),
            previewTool("XcodeCloseWorkspace"),
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace": return previewResult(["workspaceIdentifier": "owned-workspace"])
            case "XcodeListRunDestinations":
                return previewResult(["activeSchemeName": "Fixture", "activeDestinationDisplayTitle": "My Mac"])
            case "XcodeUpdate":
                #expect(call.arguments["workspaceIdentifier"] == "owned-workspace")
                #expect(call.arguments["filePath"] == "Fixture/View.swift")
                #expect(call.arguments["oldString"] == "initial source")
                #expect(call.arguments["newString"] == "edited source")
                if !editSucceeds { return previewResult(["success": false, "errorDescription": "Edit failed"])}
                try "edited source".write(to: source, atomically: true, encoding: .utf8)
            case "RenderPreview":
                let changed = try String(contentsOf: source, encoding: .utf8) == "edited source"
                return previewResult(["previewSnapshotPath": .string((changed ? edited : initial).path)])
            case "XcodeCloseWorkspace": #expect(call.arguments["workspaceIdentifier"] == "owned-workspace")
            default: break
            }
            return previewResult(["success": true])
        }
        let client = try await runtime.makeClient()
        var runner = PreviewCaptureRunner(output: root, projectRoot: root,
            project: root.appendingPathComponent("Fixture.xcworkspace"), report: captureReport(backend: .headless))
        await runner.capture(client: client, sequenceEdit: PreviewSourceEdit(oldString: "initial source", newString: "edited source"))
        await client.close()
        let samples = try #require(runner.report.samples)
        #expect(samples.map(\.condition) == (editSucceeds ? ["initial", "unchanged-repeat", "source-edit"] : ["initial", "unchanged-repeat"]))
        #expect(samples[0].sourceSHA256 == samples[1].sourceSHA256)
        #expect(try comparePreviewImages(root.appendingPathComponent(samples[0].snapshot), root.appendingPathComponent(samples[1].snapshot)).exactPixels)
        if editSucceeds {
            #expect(samples[2].sourceSHA256 != samples[0].sourceSHA256)
            #expect(try !comparePreviewImages(root.appendingPathComponent(samples[0].snapshot), root.appendingPathComponent(samples[2].snapshot)).exactPixels)
        }
        #expect(runner.report.operationSucceeded == editSucceeds)
        #expect(runner.report.workspaceClosed)
        let calls = await runtime.recordedToolCalls()
        #expect(calls.filter { $0.name == "XcodeOpenWorkspace" }.count == 1)
        #expect(calls.filter { $0.name == "XcodeCloseWorkspace" }.count == 1)
        #expect(calls.filter { $0.name == "RenderPreview" }.count == samples.count)
    }

    @Test func failedNativeCaptureCannotProduceAPassingComparison() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native")
        let headless = root.appendingPathComponent("headless")
        try createPreviewOutput(native)
        try createPreviewOutput(headless)
        var reference = captureReport(backend: .native)
        reference.failure = "Native preview could not launch"
        try writePreviewJSON(reference, to: native.appendingPathComponent("capture.json"))
        try writePreviewJSON(successfulReport(backend: .headless), to: headless.appendingPathComponent("capture.json"))
        let comparison = try PreviewComparison.compare(native: native, headless: headless)
        #expect(!comparison.passed)
        #expect(comparison.unavailableReasons.contains { $0.contains("Native capture did not succeed") })
        #expect(comparison.image == nil)
    }

    @Test func comparisonReportsMetadataAndPixelDifferences() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native")
        let headless = root.appendingPathComponent("headless")
        try createPreviewOutput(native)
        try createPreviewOutput(headless)
        let reference = successfulReport(backend: .native)
        var product = successfulReport(backend: .headless)
        try writePreviewJSON(reference, to: native.appendingPathComponent("capture.json"))
        try writePreviewJSON(product, to: headless.appendingPathComponent("capture.json"))
        try writePNG(native.appendingPathComponent("preview.png"), red: 1)
        try writePNG(headless.appendingPathComponent("preview.png"), red: 1)
        #expect(try PreviewComparison.compare(native: native, headless: headless).passed)
        product.metadata = .object(["displayName": "Different preview"])
        try writePreviewJSON(product, to: headless.appendingPathComponent("capture.json"))
        let metadata = try PreviewComparison.compare(native: native, headless: headless)
        #expect(!metadata.passed)
        #expect(metadata.metadata["displayName"]?.matches == false)
        try writePreviewJSON(successfulReport(backend: .headless), to: headless.appendingPathComponent("capture.json"))
        try writePNG(headless.appendingPathComponent("preview.png"), red: 0)
        let pixels = try PreviewComparison.compare(native: native, headless: headless)
        #expect(!pixels.passed)
        #expect(pixels.image?.differentPixels == 4)
    }

    @Test func comparisonIncludesEditedSequenceImages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native")
        let headless = root.appendingPathComponent("headless")
        try createPreviewOutput(native)
        try createPreviewOutput(headless)
        for (backend, directory) in [(PreviewBackend.native, native), (.headless, headless)] {
            var report = successfulReport(backend: backend)
            report.samples = ["initial", "unchanged-repeat", "source-edit"].map { condition in
                PreviewCaptureSample(condition: condition, elapsedSeconds: 1,
                    sourceSHA256: condition == "source-edit" ? "edited" : "original", metadata: .object(["displayName": "Preview"]),
                    snapshot: condition == "initial" ? "preview.png" : "preview-\(condition).png")
            }
            for sample in report.samples ?? [] { try writePNG(directory.appendingPathComponent(sample.snapshot), red: 1) }
            try writePreviewJSON(report, to: directory.appendingPathComponent("capture.json"))
        }
        let matching = try PreviewComparison.compare(native: native, headless: headless)
        #expect(matching.passed)
        #expect(matching.samples.count == 3)
        try writePNG(headless.appendingPathComponent("preview-source-edit.png"), red: 0)
        let stale = try PreviewComparison.compare(native: native, headless: headless)
        #expect(!stale.passed)
        #expect(stale.samples.last?.image.exactPixels == false)
        #expect(stale.image?.exactPixels == true)
    }

    @Test(arguments: ["no-op-edit", "changed-repeat", "unexpected-condition"])
    func comparisonRejectsMatchingButInvalidRequestSequences(scenario: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native")
        let headless = root.appendingPathComponent("headless")
        let conditions = ["initial", "unchanged-repeat", scenario == "unexpected-condition" ? "other" : "source-edit"]
        let digests = ["original", scenario == "changed-repeat" ? "changed" : "original",
            scenario == "no-op-edit" ? "original" : "edited"]
        for (backend, directory) in [(PreviewBackend.native, native), (.headless, headless)] {
            try createPreviewOutput(directory)
            var report = successfulReport(backend: backend)
            report.samples = zip(conditions, digests).map { condition, digest in
                PreviewCaptureSample(condition: condition, elapsedSeconds: 1, sourceSHA256: digest,
                    metadata: .object(["displayName": "Preview"]), snapshot: "preview.png")
            }
            try writePNG(directory.appendingPathComponent("preview.png"), red: 1)
            try writePreviewJSON(report, to: directory.appendingPathComponent("capture.json"))
            #expect(!report.passed)
        }
        let comparison = try PreviewComparison.compare(native: native, headless: headless)
        #expect(!comparison.passed)
    }

    private func captureReport(backend: PreviewBackend) -> PreviewCaptureReport {
        PreviewCaptureReport(backend: backend, fixture: "fixture",
            preview: PreviewVerificationCase(id: "preview", sourceFile: "View.swift", navigatorPath: "Fixture/View.swift",
                scheme: "Fixture", index: 0, arguments: [:]),
            inputFiles: ["View.swift": "same-source"], developerDirectory: "/Xcode/Contents/Developer",
            requestedDestination: "My Mac", timeout: 30)
    }

    private func successfulReport(backend: PreviewBackend) -> PreviewCaptureReport {
        var report = captureReport(backend: backend)
        report.xcodeVersion = "Fixture Xcode"
        report.operationSucceeded = true
        report.workspaceClosed = true
        report.nativeDocumentClosed = true
        report.clientClosed = true
        report.snapshot = "preview.png"
        report.metadata = .object(["displayName": "Preview"])
        return report
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-verifier-\(UUID())")
        try createPreviewOutput(root)
        return root
    }

    private func projectObjects(_ project: URL) throws -> [String: [String: Any]] {
        let value = try unsafe PropertyListSerialization.propertyList(from: Data(contentsOf: project.appendingPathComponent("project.pbxproj")), format: nil)
        return try #require((value as? [String: Any])?["objects"] as? [String: [String: Any]])
    }

    private func writePNG(_ url: URL, red: CGFloat) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = unsafe CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try #require(bitmap)
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private actor PreviewDestinationReadiness {
    private var reads = 0
    var isReady: Bool { reads > 1 }

    func readDestinations() -> Bool {
        reads += 1
        return isReady
    }
}

private func previewTool(_ name: String) -> MCPTool {
    MCPTool(name: name, inputSchema: ["type": "object", "properties": .object([:])])
}

private func previewResult(_ fields: [String: MCPJSONValue]) -> MCPToolResult {
    MCPToolResult(content: [], structuredContent: .object(fields))
}
