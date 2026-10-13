import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewProcessTests {
    @Test func diagnosticsDoNotCorruptCommandOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = try await fixture.process.run("/bin/sh", ["-c", "printf 'render-output'; printf 'render-diagnostic' >&2"])
        #expect(output == "render-output")
    }

    @Test func commandFailureIncludesItsDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.process.run("/bin/sh", ["-c", "printf 'render-failed' >&2; exit 7"])
            Issue.record("A failed preview command returned success")
        } catch let error as NativeRuntimeError {
            #expect(error.description.contains("exited with 7"))
            #expect(error.description.contains("render-failed"))
        }
    }

    @Test func cancelledCommandFinishesAfterItsChildExits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("pid")
        let command = "echo $$ > '\(marker.path)'; exec /bin/sleep 60"
        let task = Task { try await fixture.process.run("/bin/sh", ["-c", command]) }
        while !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled preview command returned success")
        } catch is CancellationError {}
        #expect(kill(pid, 0) == -1)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let process: NativePreviewProcess

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            let app = root.appendingPathComponent("Xcode.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/IDEFoundation.framework"), withIntermediateDirectories: true)
            process = NativePreviewProcess(installation: try NativeXcodeInstallation(developerDirectory: app), artifacts: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
