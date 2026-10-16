#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS) || os(watchOS)
import Foundation
import XcodeMCPWire

func previewRendererSessionDirectory() throws -> URL? {
    guard let index = CommandLine.arguments.firstIndex(of: "--preview-session-directory") else { return nil }
    guard CommandLine.arguments.indices.contains(index + 1) else {
        throw PreviewRendererError("The preview renderer requires a session directory")
    }
    let value = CommandLine.arguments[index + 1]
    if value.hasPrefix("automatic:") {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return support.appendingPathComponent("XcodeMCPPreviewSessions", isDirectory: true)
            .appendingPathComponent(String(value.dropFirst("automatic:".count)), isDirectory: true)
    }
    return URL(filePath: value, directoryHint: .isDirectory)
}

@MainActor
func runPreviewRendererSession(in directory: URL,
                               render: @MainActor (PreviewRendererRequest, URL) async throws -> PreviewRendererResult) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileHandle.standardOutput.write(contentsOf: Data(("XcodeMCPPreviewSession:\(directory.path)\n"
        + "XcodeMCPPreviewProcess:\(ProcessInfo.processInfo.processIdentifier)\n").utf8))
    let requestURL = directory.appendingPathComponent("PreviewRequest.json")
    var completedIdentifier: String?
    while true {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: requestURL.path) {
            let command = try JSONDecoder().decode(PreviewRendererCommand.self, from: Data(contentsOf: requestURL))
            if command.identifier != completedIdentifier {
                let output = directory.appendingPathComponent(command.identifier, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                var result: PreviewRendererResult
                do { result = try await render(command.request, output) }
                catch is CancellationError { throw CancellationError() }
                catch is NativePreviewPipelineRequired { result = PreviewRendererResult(requiresNativePipeline: true) }
                catch { result = PreviewRendererResult(error: String(describing: error)) }
                if let data = result.snapshotData {
                    try data.write(to: output.appendingPathComponent("Preview.png"), options: .atomic)
                    result.snapshotName = "Preview.png"
                    result.snapshotData = nil
                }
                try JSONEncoder().encode(result).write(to: output.appendingPathComponent("PreviewResult.json"), options: .atomic)
                completedIdentifier = command.identifier
            }
        }
        try await Task.sleep(for: .milliseconds(25))
    }
}
#endif
