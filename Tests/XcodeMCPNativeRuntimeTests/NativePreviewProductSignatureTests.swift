import Darwin
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewProductSignatureTests {
    @Test func reusesProductsWhenNativeTargetOrderChanges() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.product.appendingPathComponent("Support.dylib")
        try Data("support".utf8).write(to: output)
        let support = NativePreviewBuild.Target(moduleName: "Support", buildableName: "Support.dylib", sdkRoot: "iphonesimulator",
            sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", output.path], linkerWorkingDirectory: nil,
            objectFiles: [], sourceFiles: [], debugDylibEnabled: false, isRunnable: false)

        let before = try fixture.signature(targets: [fixture.target, support])

        #expect(try fixture.signature(targets: [support, fixture.target]) == before)
    }

    @Test func reusesProductsAfterFileMetadataChangesWithoutContentChanges() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let info = fixture.product.appendingPathComponent("Info.plist")
        try Data("unchanged".utf8).write(to: info)
        let before = try fixture.signature()

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: info.path)

        #expect(try fixture.signature() == before)
    }

    @Test func detectsResourceChangesWhenSizeAndModificationTimeArePreserved() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resource = fixture.product.appendingPathComponent("Label.txt")
        try Data("old".utf8).write(to: resource)
        var original = stat()
        try #require(unsafe lstat(resource.path, &original) == 0)
        let before = try fixture.signature()

        let file = try FileHandle(forWritingTo: resource)
        try file.write(contentsOf: Data("new".utf8))
        try file.close()
        let times = [original.st_atimespec, original.st_mtimespec]
        let restored = unsafe times.withUnsafeBufferPointer {
            unsafe utimensat(AT_FDCWD, resource.path, $0.baseAddress, 0)
        }
        try #require(restored == 0)
        var changed = stat()
        try #require(unsafe lstat(resource.path, &changed) == 0)

        #expect(changed.st_ino == original.st_ino)
        #expect(changed.st_size == original.st_size)
        #expect(changed.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
        #expect(changed.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
        #expect(try fixture.signature() != before)
    }

    @Test func detectsResourceInventoryAndLaunchSettingChanges() throws {
        var fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try fixture.signature()
        let resource = fixture.product.appendingPathComponent("Added.txt")
        try Data("resource".utf8).write(to: resource)
        let added = try fixture.signature()
        #expect(added != before)

        try FileManager.default.removeItem(at: resource)
        let removed = try fixture.signature()
        #expect(removed != added)

        fixture.target.rendererEnvironment["PREVIEW_MODE"] = "updated"
        #expect(try fixture.signature() != removed)
    }

    @Test func detectsAtomicallyReplacedResources() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resource = fixture.product.appendingPathComponent("Label.txt")
        try Data("old".utf8).write(to: resource)
        var original = stat()
        try #require(unsafe lstat(resource.path, &original) == 0)
        let before = try fixture.signature()

        let replacement = fixture.root.appendingPathComponent("Replacement.txt")
        try Data("new".utf8).write(to: replacement)
        let times = [original.st_atimespec, original.st_mtimespec]
        try #require(unsafe times.withUnsafeBufferPointer {
            unsafe utimensat(AT_FDCWD, replacement.path, $0.baseAddress, 0)
        } == 0)
        try #require(unsafe rename(replacement.path, resource.path) == 0)
        var changed = stat()
        try #require(unsafe lstat(resource.path, &changed) == 0)

        #expect(changed.st_ino != original.st_ino)
        #expect(changed.st_size == original.st_size)
        #expect(changed.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
        #expect(changed.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
        #expect(try fixture.signature() != before)
    }

    @Test func detectsSymbolicLinkRetargetingAndTargetChanges() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.root.appendingPathComponent("First.txt")
        let second = fixture.root.appendingPathComponent("Second.txt")
        let link = fixture.product.appendingPathComponent("Label.txt")
        try Data("old".utf8).write(to: first)
        try Data("old".utf8).write(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let before = try fixture.signature()

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        let retargeted = try fixture.signature()
        #expect(retargeted != before)

        try Data("new".utf8).write(to: second)
        #expect(try fixture.signature() != retargeted)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let product: URL
        let helper: URL
        let source: URL
        let digestCache = NativePreviewProductSignature.DigestCache()
        var target: NativePreviewBuild.Target

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            product = root.appendingPathComponent("Fixture.app")
            helper = root.appendingPathComponent("Renderer")
            source = root.appendingPathComponent("View.swift")
            try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
            let binary = product.appendingPathComponent("Fixture")
            try Data("binary".utf8).write(to: binary)
            try Data("renderer".utf8).write(to: helper)
            target = NativePreviewBuild.Target(moduleName: "Fixture", buildableName: "Fixture.app", sdkRoot: "iphonesimulator",
                sdkVariant: nil, architecture: "arm64", linkCommandLine: ["-o", binary.path], linkerWorkingDirectory: nil,
                objectFiles: [], sourceFiles: [source], debugDylibEnabled: true, isRunnable: true)
        }

        func signature(targets: [NativePreviewBuild.Target]? = nil) throws -> NativePreviewProductSignature {
            let build = NativePreviewBuild.Result(targets: targets ?? [target], previewRoots: [], destinationIdentifier: "destination",
                previewDestinationIdentifier: "preview-destination", platformIdentifier: "com.apple.platform.iphonesimulator",
                previewPlatform: .iOS, platformName: "iOS", deviceModelName: "iPhone", systemVersion: "27.1")
            return try NativePreviewProductSignature(build: build, source: source, helper: helper,
                digestCache: digestCache)
        }
    }
}
