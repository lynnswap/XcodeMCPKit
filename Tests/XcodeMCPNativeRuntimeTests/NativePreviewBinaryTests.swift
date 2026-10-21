import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewBinaryTests {
    @Test func discoversPreviewSymbolsInTheArm64Image() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = "7Fixture04ViewfMu_V"
        let importedRegistry = "12ExternalViewfMu_V"
        let appRoot = "10FixtureApp0B0V"
        var libraries: [URL] = []
        for architecture in ["arm64", "x86_64"] {
            let source = root.appendingPathComponent(architecture + ".c")
            let library = root.appendingPathComponent(architecture + ".dylib")
            let selectedRoot = architecture == "arm64" ? appRoot : "12OtherAppRootV"
            let code = """
                int registry __asm__("_$s\(registry)Mn") = 1;
                extern void imported_registry(void) __asm__("_$s\(importedRegistry)Mn");
                extern void imported_main(void) __asm__("_$s12ExternalRootV5$mainyyFZ");
                void preview_main(void) __asm__("_$s\(selectedRoot)5$mainyyFZ");
                void preview_main(void) { imported_main(); imported_registry(); }
                """
            try Data(code.utf8).write(to: source)
            try await previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", architecture,
                "-dynamiclib", source.path, "-Wl,-undefined,dynamic_lookup", "-o", library.path])
            libraries.append(library)
        }
        let universal = root.appendingPathComponent("universal.dylib")
        try await previewBinaryOutput("/usr/bin/xcrun", ["lipo", "-create"] + libraries.map(\.path) + ["-output", universal.path])

        let symbols = try NativePreviewBinary.previewSymbols(in: [libraries[0], universal])
        #expect(symbols.registryNames == [importedRegistry, registry].sorted())
        #expect(symbols.programRootNames == [appRoot])
    }

    @Test func signedCopiesRetainBinaryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let arm64 = root.appendingPathComponent("arm64.dylib")
        let signed = root.appendingPathComponent("signed.dylib")
        try await compilePreviewLibrary(at: arm64)
        try FileManager.default.copyItem(at: arm64, to: signed)
        try await previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", signed.path])

        #expect(try Data(contentsOf: arm64) != Data(contentsOf: signed))
        #expect(try NativePreviewBinary.matches(arm64, signed))
    }

    @Test func uuidlessLibrariesCompareTheirBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.dylib")
        let copy = root.appendingPathComponent("copy.dylib")
        let other = root.appendingPathComponent("other.dylib")
        try await compilePreviewLibrary(at: source, uuid: false)
        try FileManager.default.copyItem(at: source, to: copy)
        try await compilePreviewLibrary(at: other, value: 1, uuid: false)

        #expect(try NativePreviewBinary.matches(source, copy))
        #expect(try !NativePreviewBinary.matches(source, other))
    }

    @Test func universalArchivesAreNotMachOImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.c")
        try Data("int preview_fixture_value(void) { return 0; }\n".utf8).write(to: source)
        var archives: [URL] = []
        for architecture in ["arm64", "x86_64"] {
            let object = root.appendingPathComponent(architecture + ".o")
            let archive = root.appendingPathComponent(architecture + ".a")
            try await previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-arch", architecture,
                "-c", source.path, "-o", object.path])
            try await previewBinaryOutput("/usr/bin/xcrun", ["libtool", "-static", object.path, "-o", archive.path])
            archives.append(archive)
        }
        let universal = root.appendingPathComponent("universal.a")
        try await previewBinaryOutput("/usr/bin/xcrun", ["lipo", "-create"] + archives.map(\.path) + ["-output", universal.path])

        #expect(try !NativePreviewBinary.isStaticLibrary(at: universal))
    }
}

@MainActor
func compilePreviewLibrary(at binary: URL, value: Int = 0, uuid: Bool = true,
                           platform: NativePreviewPlatform = .iOS, installName: String = "@rpath/libPreviewFixture.dylib",
                           libraries: [URL] = []) async throws {
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = binary.appendingPathExtension("c")
    try Data("int preview_fixture_value(void) { return \(value); }\n".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let sdk = try await previewBinaryOutput("/usr/bin/xcrun", ["--sdk", platform.sdk, "--show-sdk-path"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var arguments = ["--sdk", platform.sdk, "clang", "-dynamiclib", "-target", platform.triple,
                     "-isysroot", sdk, source.path, "-install_name", installName, "-o", binary.path,
                     "-Wl,-no_adhoc_codesign"] + libraries.map(\.path)
    if !uuid { arguments.append("-Wl,-no_uuid") }
    try await previewBinaryOutput("/usr/bin/xcrun", arguments)
}

/// Runs a tool and returns its combined output. It waits for the tool to exit without blocking
/// the calling thread: these suites run on the main actor, which suites running in parallel share.
@discardableResult
func previewBinaryOutput(_ executable: String, _ arguments: [String]) async throws -> String {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString).log")
    try Data().write(to: log)
    defer { try? FileManager.default.removeItem(at: log) }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    // Unlike a pipe, a file never fills up while nothing reads it.
    process.standardOutput = output
    process.standardError = output
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NativeRuntimeError.invocation("\(executable) exited with \(process.terminationStatus): \(text)")
    }
    return text
}
