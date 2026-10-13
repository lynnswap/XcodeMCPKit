import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewCorrectionTests {
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
