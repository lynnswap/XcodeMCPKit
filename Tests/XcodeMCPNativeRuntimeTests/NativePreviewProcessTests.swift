import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewProcessTests {
    @Test func rendererDirectoryEventsObserveAtomicReplacements() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("PreviewRequest.json")
        try Data("before".utf8).write(to: file, options: .atomic)

        let value = try await PreviewRendererFileEvents.withEvents(in: fixture.root) { changes, _ in
            #expect(try String(contentsOf: file, encoding: .utf8) == "before")
            var events = changes.makeAsyncIterator()
            let registered = await events.next()
            #expect(registered != nil)

            try Data("after".utf8).write(to: file, options: .atomic)
            let changed = await events.next()
            #expect(changed != nil)
            return try String(contentsOf: file, encoding: .utf8)
        }
        #expect(value == "after")
    }

    @Test func cancelledRendererDirectoryWaitFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.continuation.finish() }
            try await PreviewRendererFileEvents.withEvents(in: fixture.root) { changes, _ in
                var events = changes.makeAsyncIterator()
                _ = await events.next()
                ready.continuation.yield(())
                while await events.next() != nil { try Task.checkCancellation() }
                try Task.checkCancellation()
            }
        }
        defer { task.cancel() }
        var readiness = ready.stream.makeAsyncIterator()
        _ = await readiness.next()
        task.cancel()

        do {
            try await task.value
            Issue.record("A cancelled renderer directory wait returned success")
        } catch is CancellationError {}
    }

    @Test func localizedRendererUsesRequestedBundleResourcesAndLocale() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = fixture.root.appendingPathComponent("Localized.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Localized")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (language, text) in [("en", "Hello"), ("ja", "こんにちは")] {
            let directory = resources.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\"Greeting\" = \"\(text)\";\n".utf8).write(to: directory.appendingPathComponent("Localizable.strings"))
        }
        let info = ["CFBundleExecutable": "Localized", "CFBundleIdentifier": "dev.lynnswap.LocalizationFixture",
                    "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let source = fixture.root.appendingPathComponent("Localized.m")
        try Data(#"""
        #import <Foundation/Foundation.h>
        int main(void) {
            @autoreleasepool {
                puts([[NSBundle mainBundle] localizedStringForKey:@"Greeting" value:@"missing" table:nil].UTF8String);
                puts([NSLocale currentLocale].localeIdentifier.UTF8String);
            }
        }
        """#.utf8).write(to: source)
        let compile = Process()
        compile.executableURL = URL(filePath: "/usr/bin/xcrun")
        compile.arguments = ["--sdk", "macosx", "clang", "-framework", "Foundation", source.path, "-o", executable.path]
        let diagnostics = Pipe()
        compile.standardOutput = diagnostics
        compile.standardError = diagnostics
        try compile.run()
        let output = diagnostics.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0, "\(String(decoding: output, as: UTF8.self))")
        for (locale, greeting) in [("ja_JP", "こんにちは"), ("en_US", "Hello")] {
            let output = try await fixture.process.run(executable.path, NativePreviewCorrection.rendererArguments(localization: locale))
            #expect(output == "\(greeting)\n\(locale)\n")
        }
    }

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
