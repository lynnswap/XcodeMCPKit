import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewEntitlementsTests {
    @Test(arguments: [false, true])
    func signedAndSimulatorEntitlementsRemainDistinct(universal: Bool) async throws {
        let simulator = try plist(["application-identifier": "FIXTURE.dev.lynnswap.Preview",
                                   "com.apple.security.application-groups": ["group.dev.lynnswap.Preview"]])
        let signed = ["keychain-access-groups": ["FIXTURE.dev.lynnswap.SharedKeychain"]]
        let product = try await Product(simulator: simulator, universal: universal)
        defer { try? FileManager.default.removeItem(at: product.root) }
        let signedURL = product.root.appendingPathComponent("signed.plist")
        try plist(signed).write(to: signedURL)
        try await previewBinaryOutput("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", signedURL.path, product.bundle.path])

        let entitlements = try NativePreviewEntitlements.read(from: product.bundle)
        #expect(entitlements.simulator == simulator)
        let signedData = try #require(entitlements.signed)
        let dictionary = try PropertyListDecoder().decode([String: [String]].self, from: signedData)
        #expect(dictionary == signed)
    }

    @Test func unsignedProductWithoutEntitlementsIsAllowed() async throws {
        let product = try await Product(simulator: nil)
        defer { try? FileManager.default.removeItem(at: product.root) }
        let entitlements = try NativePreviewEntitlements.read(from: product.bundle)
        #expect(entitlements.signed == nil)
        #expect(entitlements.simulator == nil)
    }

    @Test func unsignedSimulatorCapabilitiesRemainAvailable() async throws {
        let simulator = try plist(["application-identifier": "FIXTURE.dev.lynnswap.Preview"])
        let product = try await Product(simulator: simulator)
        defer { try? FileManager.default.removeItem(at: product.root) }
        let entitlements = try NativePreviewEntitlements.read(from: product.bundle)
        #expect(entitlements.signed == nil)
        #expect(entitlements.simulator == simulator)
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}

@MainActor
private struct Product {
    let root: URL
    let bundle: URL

    init(simulator: Data?, universal: Bool = false) async throws {
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
            let sdk = try await previewBinaryOutput("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let executable = bundle.appendingPathComponent("Original")
            let arm64 = universal ? root.appendingPathComponent("arm64") : executable
            let baseArguments = ["--sdk", "iphonesimulator", "clang", "-isysroot", sdk, source.path,
                                 "-Wl,-no_adhoc_codesign"]
            var arguments = baseArguments + ["-target", "arm64-apple-ios18.4-simulator", "-o", arm64.path]
            if let simulator {
                let entitlements = root.appendingPathComponent("simulator.plist")
                try simulator.write(to: entitlements)
                arguments += ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", entitlements.path]
            }
            try await previewBinaryOutput("/usr/bin/xcrun", arguments)
            if universal {
                let x86_64 = root.appendingPathComponent("x86_64")
                try await previewBinaryOutput("/usr/bin/xcrun", baseArguments + ["-target", "x86_64-apple-ios18.4-simulator", "-o", x86_64.path])
                try await previewBinaryOutput("/usr/bin/xcrun", ["lipo", "-create", x86_64.path, arm64.path, "-output", executable.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
