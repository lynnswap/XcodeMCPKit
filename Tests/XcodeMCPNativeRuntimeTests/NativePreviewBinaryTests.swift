import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewBinaryTests {
    @Test(arguments: ["arm64", "x86_64"])
    func signedAndThinnedCopiesRetainBinaryIdentity(architecture: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let arm64 = root.appendingPathComponent("arm64.dylib")
        let intel = root.appendingPathComponent("intel.dylib")
        let universal = root.appendingPathComponent("universal.dylib")
        let signed = root.appendingPathComponent("signed.dylib")
        try compilePreviewLibrary(at: arm64)
        try compilePreviewLibrary(at: intel, architecture: "x86_64")
        try previewBinaryOutput("/usr/bin/xcrun", ["lipo", "-create", arm64.path, intel.path, "-output", universal.path])
        try previewBinaryOutput("/usr/bin/xcrun", ["lipo", universal.path, "-thin", architecture, "-output", signed.path])
        try previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", signed.path])

        #expect(try Data(contentsOf: architecture == "arm64" ? arm64 : intel) != Data(contentsOf: signed))
        #expect(try NativePreviewBinary.matches(universal, signed, architecture: architecture))
    }

    @Test func uuidlessLibrariesMatchOnlyExactCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.dylib")
        let copy = root.appendingPathComponent("copy.dylib")
        let other = root.appendingPathComponent("other.dylib")
        try compilePreviewLibrary(at: source, uuid: false)
        try FileManager.default.copyItem(at: source, to: copy)
        try compilePreviewLibrary(at: other, value: 1, uuid: false)

        #expect(try NativePreviewBinary.matches(source, copy, architecture: "arm64"))
        #expect(try !NativePreviewBinary.matches(source, other, architecture: "arm64"))
    }
}

@MainActor
func compilePreviewLibrary(at binary: URL, value: Int = 0, uuid: Bool = true, architecture: String = "arm64") throws {
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = binary.appendingPathExtension("c")
    try Data("int preview_fixture_value(void) { return \(value); }\n".utf8).write(to: source)
    let sdk = try previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var arguments = ["--sdk", "iphonesimulator", "clang", "-dynamiclib", "-target", "\(architecture)-apple-ios18.4-simulator",
                     "-isysroot", sdk, source.path, "-install_name", "@rpath/libPreviewFixture.dylib", "-o", binary.path,
                     "-Wl,-no_adhoc_codesign"]
    if !uuid { arguments.append("-Wl,-no_uuid") }
    try previewBinaryOutput("/usr/bin/xcrun", arguments)
}

@discardableResult
@MainActor
private func previewBinaryOutput(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NativeRuntimeError.invocation("\(executable) exited with \(process.terminationStatus): \(text)")
    }
    return text
}
