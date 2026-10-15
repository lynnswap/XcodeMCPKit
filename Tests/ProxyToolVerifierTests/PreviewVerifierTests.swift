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

    @Test func failedSelectionStopsRenderingAndClosesOnlyTheOwnedWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = XcodeMCPTestRuntime(tools: [
            previewTool("XcodeOpenWorkspace"), previewTool("XcodeSwitchScheme"),
            previewTool("XcodeSwitchRunDestination"), previewTool("XcodeCloseWorkspace"), previewTool("RenderPreview")
        ])
        await runtime.setToolHandler { call in
            switch call.name {
            case "XcodeOpenWorkspace": return previewResult(["workspaceIdentifier": "owned-workspace"])
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
        var runner = PreviewCaptureRunner(output: root, projectRoot: root, project: root.appendingPathComponent("Fixture.xcodeproj"),
            report: captureReport(backend: .headless))
        await runner.capture(client: client)
        await client.close()
        #expect(!runner.report.operationSucceeded)
        #expect(runner.report.workspaceClosed)
        #expect(runner.report.failure?.contains("Destination unavailable") == true)
        #expect(await runtime.recordedToolCalls().filter { $0.name == "XcodeCloseWorkspace" }.count == 1)
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

private func previewTool(_ name: String) -> MCPTool {
    MCPTool(name: name, inputSchema: ["type": "object", "properties": .object([:])])
}

private func previewResult(_ fields: [String: MCPJSONValue]) -> MCPToolResult {
    MCPToolResult(content: [], structuredContent: .object(fields))
}
