import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewEntitlementsTests {
    @Test func signedAndSimulatorEntitlementsRemainDistinct() throws {
        let simulator = try plist(["application-identifier": "FIXTURE.dev.lynnswap.Preview",
                                   "com.apple.security.application-groups": ["group.dev.lynnswap.Preview"]])
        let signed = ["keychain-access-groups": ["FIXTURE.dev.lynnswap.SharedKeychain"]]
        let product = try Product(simulator: simulator)
        defer { try? FileManager.default.removeItem(at: product.root) }
        let signedURL = product.root.appendingPathComponent("signed.plist")
        try plist(signed).write(to: signedURL)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", signedURL.path, product.bundle.path])

        let entitlements = try NativePreviewEntitlements.read(from: product.bundle, architecture: "arm64")
        #expect(entitlements.simulator == simulator)
        let signedData = try #require(entitlements.signed)
        let dictionary = try PropertyListDecoder().decode([String: [String]].self, from: signedData)
        #expect(dictionary == signed)
    }

    @Test func unsignedProductWithoutEntitlementsIsAllowed() throws {
        let product = try Product(simulator: nil)
        defer { try? FileManager.default.removeItem(at: product.root) }
        let entitlements = try NativePreviewEntitlements.read(from: product.bundle, architecture: "arm64")
        #expect(entitlements.signed == nil)
        #expect(entitlements.simulator == nil)
    }

    @Test func unsignedSimulatorCapabilitiesRemainAvailable() throws {
        let simulator = try plist(["application-identifier": "FIXTURE.dev.lynnswap.Preview"])
        let product = try Product(simulator: simulator)
        defer { try? FileManager.default.removeItem(at: product.root) }
        let entitlements = try NativePreviewEntitlements.read(from: product.bundle, architecture: "arm64")
        #expect(entitlements.signed == nil)
        #expect(entitlements.simulator == simulator)
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    @Test func universalProductUsesSelectedArchitectureEntitlements() throws {
        let arm = try Product(simulator: plist(["application-identifier": "ARM.dev.lynnswap.Preview"]))
        defer { try? FileManager.default.removeItem(at: arm.root) }
        let intelSimulator = try plist(["application-identifier": "INTEL.dev.lynnswap.Preview"])
        let intel = try Product(simulator: intelSimulator, architecture: "x86_64")
        defer { try? FileManager.default.removeItem(at: intel.root) }
        for (product, team) in [(arm, "ARM"), (intel, "INTEL")] {
            let entitlementsURL = product.root.appendingPathComponent("signed.plist")
            try plist(["keychain-access-groups": ["\(team).dev.lynnswap.SharedKeychain"]]).write(to: entitlementsURL)
            try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, product.bundle.path])
        }
        let universal = arm.root.appendingPathComponent("Universal")
        try run("/usr/bin/xcrun", ["lipo", "-create", arm.bundle.appendingPathComponent("Original").path,
                                  intel.bundle.appendingPathComponent("Original").path, "-output", universal.path])
        try FileManager.default.removeItem(at: arm.bundle.appendingPathComponent("Original"))
        try FileManager.default.moveItem(at: universal, to: arm.bundle.appendingPathComponent("Original"))
        let entitlements = try NativePreviewEntitlements.read(from: arm.bundle, architecture: "x86_64")
        #expect(entitlements.simulator == intelSimulator)
        let signed = try #require(entitlements.signed)
        #expect(try PropertyListDecoder().decode([String: [String]].self, from: signed)
            == ["keychain-access-groups": ["INTEL.dev.lynnswap.SharedKeychain"]])
    }
}

@MainActor
private struct Product {
    let root: URL
    let bundle: URL

    init(simulator: Data?, architecture: String = "arm64") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-entitlements-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        do {
            let info = ["CFBundleIdentifier": "dev.lynnswap.PreviewEntitlementsFixture",
                        "CFBundleExecutable": "Original", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Info.plist"))
            let source = root.appendingPathComponent("main.c")
            try Data("int main(void) { return 0; }\n".utf8).write(to: source)
            let sdk = try output("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var arguments = ["--sdk", "iphonesimulator", "clang", "-target", "\(architecture)-apple-ios18.4-simulator",
                             "-isysroot", sdk, source.path, "-o", bundle.appendingPathComponent("Original").path,
                             "-Wl,-no_adhoc_codesign"]
            if let simulator {
                let entitlements = root.appendingPathComponent("simulator.plist")
                try simulator.write(to: entitlements)
                arguments += ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", entitlements.path]
            }
            try run("/usr/bin/xcrun", arguments)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private func run(_ executable: String, _ arguments: [String]) throws {
    _ = try output(executable, arguments)
}

private func output(_ executable: String, _ arguments: [String]) throws -> String {
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
