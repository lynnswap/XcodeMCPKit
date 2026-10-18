import Foundation
import XcodeMCPKit

enum PreviewBackend: String, Codable, Sendable { case native, headless }

struct PreviewSourceEdit: Codable, Sendable {
    let oldString: String
    let newString: String
}

struct PreviewCaptureSample: Codable {
    let condition: String
    let elapsedSeconds: TimeInterval
    let sourceSHA256: String
    let metadata: MCPJSONValue
    let snapshot: String
}

struct PreviewCaptureReport: Codable {
    let backend: PreviewBackend
    let fixture: String
    let preview: PreviewVerificationCase
    let inputFiles: [String: String]
    let developerDirectory: String
    let requestedDestination: String
    let timeout: Int
    var xcodeVersion: String?
    var executable: String?
    var executableSHA256: String?
    var selectedDestination: MCPJSONValue?
    var records: [ToolVerificationRecord] = []
    var samples: [PreviewCaptureSample]?
    var metadata: MCPJSONValue?
    var snapshot: String?
    var operationSucceeded = false
    var failure: String?
    var cleanupErrors: [String] = []
    var workspaceClosed = false
    var nativeDocumentClosed = false
    var clientClosed = false

    var passed: Bool {
        operationSucceeded && failure == nil && cleanupErrors.isEmpty && clientClosed
            && (backend == .headless ? workspaceClosed : nativeDocumentClosed)
    }
}

struct PreviewCaptureRunner {
    let output: URL
    let projectRoot: URL
    let project: URL
    var report: PreviewCaptureReport

    mutating func capture(client: XcodeMCP, sequenceEdit: PreviewSourceEdit? = nil) async {
        var openedWorkspace: String?
        do {
            let tools = try await client.listTools()
            try writePreviewJSON(tools.map(\.raw), to: output.appendingPathComponent("tool-catalog.json"))
            let selector: [String: MCPJSONValue]
            if report.backend == .headless {
                let workspace: URL
                if project.pathExtension == "xcworkspace" {
                    workspace = project
                } else {
                    workspace = output.appendingPathComponent("Preview.xcworkspace", isDirectory: true)
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
                    try writeVerifierWorkspace(at: workspace, project: project)
                }
                let result = try await call("XcodeOpenWorkspace", arguments: ["path": .string(workspace.path)], client: client)
                guard let raw = result.rawResult, let identifier = parseFirstString(named: "workspaceIdentifier", from: raw) else {
                    throw VerifierFailure("XcodeOpenWorkspace did not return its owned workspace identifier")
                }
                openedWorkspace = identifier
                selector = ["workspaceIdentifier": .string(identifier)]
            } else {
                selector = ["tabIdentifier": .string(try await nativeTab(client: client))]
            }
            _ = try await call("XcodeSwitchScheme", arguments: selector.merging(["schemeName": .string(report.preview.scheme)]) { _, value in value }, client: client)
            if report.backend == .native {
                try await waitForNativeDestinations(selector: selector, client: client)
            }
            _ = try await call("XcodeSwitchRunDestination", arguments: selector.merging(["displayTitle": .string(report.requestedDestination)]) { _, value in value }, client: client)
            let selection = try await call("XcodeListRunDestinations", arguments: selector, client: client)
            guard let rawSelection = selection.rawResult,
                  let selected = previewStructuredContent(rawSelection),
                  selected["activeSchemeName"]?.stringValue == report.preview.scheme,
                  selected["activeDestinationDisplayTitle"]?.stringValue == report.requestedDestination else {
                throw VerifierFailure("The requested scheme and destination were not selected")
            }
            report.selectedDestination = .object(selected)
            var arguments = report.preview.arguments
            arguments.merge(selector) { _, value in value }
            arguments["sourceFilePath"] = .string(report.preview.navigatorPath)
            arguments["previewDefinitionIndexInFile"] = .integer(Int64(report.preview.index))
            arguments["timeout"] = .integer(Int64(report.timeout))
            let initial = try await captureSample(condition: "initial", arguments: arguments, client: client)
            report.metadata = initial.metadata
            report.snapshot = initial.snapshot
            if let sequenceEdit {
                report.samples = [initial]
                let repeated = try await captureSample(condition: "unchanged-repeat", arguments: arguments, client: client)
                report.samples?.append(repeated)
                _ = try await call("XcodeUpdate", arguments: selector.merging([
                    "filePath": .string(report.preview.navigatorPath),
                    "oldString": .string(sequenceEdit.oldString), "newString": .string(sequenceEdit.newString),
                ]) { _, value in value }, client: client)
                let edited = try await captureSample(condition: "source-edit", arguments: arguments, client: client)
                report.samples?.append(edited)
            }
            report.operationSucceeded = true
        } catch { report.failure = errorDescription(error) }
        if let openedWorkspace {
            do {
                _ = try await call("XcodeCloseWorkspace", arguments: ["workspaceIdentifier": .string(openedWorkspace)], client: client)
                report.workspaceClosed = true
            } catch { report.cleanupErrors.append(errorDescription(error)) }
        }
        do { try save() } catch { report.cleanupErrors.append("Cannot save capture: \(errorDescription(error))") }
    }

    private mutating func captureSample(condition: String, arguments: [String: MCPJSONValue], client: XcodeMCP) async throws -> PreviewCaptureSample {
        let digest = try previewSHA256(projectRoot.appendingPathComponent(report.preview.sourceFile))
        let rendered = try await call("RenderPreview", arguments: arguments, client: client)
        guard let raw = rendered.rawResult, let metadata = previewStructuredContent(raw) else {
            throw VerifierFailure("RenderPreview returned no structured metadata")
        }
        let name = condition == "initial" ? "preview.png" : "preview-\(condition).png"
        try savePreviewSnapshot(raw: raw, metadata: metadata, to: output.appendingPathComponent(name))
        let sample = PreviewCaptureSample(condition: condition, elapsedSeconds: rendered.elapsedSeconds,
            sourceSHA256: digest, metadata: .object(metadata), snapshot: name)
        try writePreviewJSON(sample, to: output.appendingPathComponent("capture-\(condition).json"))
        return sample
    }

    private mutating func call(_ name: String, arguments: [String: MCPJSONValue], client: XcodeMCP) async throws -> ToolVerificationRecord {
        print("-> \(name)")
        let record = await callVerifierTool(name, arguments: arguments, client: client)
        report.records.append(record)
        try save()
        guard record.status == .passed else { throw VerifierFailure("\(name): \(record.detail)") }
        return record
    }

    private mutating func waitForNativeDestinations(selector: [String: MCPJSONValue], client: XcodeMCP) async throws {
        // Package schemes can appear before Xcode finishes resolving their destinations.
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        repeat {
            let result = try await call("XcodeListRunDestinations", arguments: selector, client: client)
            let count = result.rawResult.flatMap(previewStructuredContent)?["totalDestinations"]?.integerValue
            if count != 0 { return }
            try await Task.sleep(for: .milliseconds(500))
        } while ContinuousClock.now < deadline
        throw VerifierFailure("Xcode did not resolve run destinations for \(report.preview.scheme) within 45 seconds")
    }

    private mutating func nativeTab(client: XcodeMCP) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        repeat {
            let result = try await call("XcodeListWindows", arguments: [:], client: client)
            if let raw = result.rawResult,
               let message = previewStructuredContent(raw)?["message"]?.stringValue,
               let identifier = previewTabIdentifier(in: message, project: project) {
                return identifier
            }
            try await Task.sleep(for: .milliseconds(500))
        } while ContinuousClock.now < deadline
        throw VerifierFailure("The selected Xcode process did not open the owned fixture: \(project.path)")
    }

    func save() throws { try writePreviewJSON(report, to: output.appendingPathComponent("capture.json")) }
}

func previewTabIdentifier(in message: String, project: URL) -> String? {
    let projectPath = project.resolvingSymlinksInPath().path
    for line in message.split(separator: "\n") {
        let fields = line.components(separatedBy: ", workspacePath: ")
        guard fields.count == 2, URL(filePath: fields[1]).resolvingSymlinksInPath().path == projectPath,
              let marker = fields[0].range(of: "tabIdentifier: ") else { continue }
        return String(fields[0][marker.upperBound...])
    }
    return nil
}

func previewStructuredContent(_ raw: MCPJSONValue) -> [String: MCPJSONValue]? {
    if let object = raw["structuredContent"]?.objectValue { return object }
    for item in raw["content"]?.arrayValue ?? [] {
        guard let text = item["text"]?.stringValue,
              let object = try? JSONDecoder().decode(MCPJSONValue.self, from: Data(text.utf8)).objectValue else { continue }
        return object
    }
    return nil
}

func savePreviewSnapshot(raw: MCPJSONValue, metadata: [String: MCPJSONValue], to output: URL) throws {
    if let path = metadata["previewSnapshotPath"]?.stringValue {
        try FileManager.default.copyItem(at: URL(filePath: path), to: output)
        return
    }
    for item in raw["content"]?.arrayValue ?? [] {
        guard item["type"]?.stringValue == "image", let encoded = item["data"]?.stringValue,
              let data = Data(base64Encoded: encoded) else { continue }
        try data.write(to: output)
        return
    }
    throw VerifierFailure("RenderPreview returned no snapshot")
}
