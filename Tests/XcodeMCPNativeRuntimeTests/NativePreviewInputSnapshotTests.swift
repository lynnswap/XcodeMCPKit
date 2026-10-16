import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativePreviewInputSnapshotTests {
    @Test func detectsImmediateChangesToExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("View.swift")
        try Data("before".utf8).write(to: file)
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: [file])
        #expect(before.predates(buildStarted))
        #expect(try NativePreviewInputSnapshot.capture(roots: [file]) == before)

        try Data("after".utf8).write(to: file)

        let after = try NativePreviewInputSnapshot.capture(roots: [file])
        #expect(after != before)
        #expect(!after.predates(buildStarted))
    }

    @Test func detectsNewAndRemovedResourceDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try NativePreviewInputSnapshot.capture(roots: [root])
        let resources = root.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try Data("resource".utf8).write(to: resources.appendingPathComponent("Label.txt"))
        let added = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(added != before)

        try FileManager.default.removeItem(at: resources)

        #expect(try NativePreviewInputSnapshot.capture(roots: [root]) != added)
    }

    @Test func followsExternalSymbolicLinkTargetsAndRetargeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let first = external.appendingPathComponent("First", isDirectory: true)
        let second = external.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let file = first.appendingPathComponent("Label.txt")
        try Data("before".utf8).write(to: file)
        let link = root.appendingPathComponent("LinkedResources")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("Back"), withDestinationURL: root)
        let before = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(try NativePreviewInputSnapshot.capture(roots: [root, first]) == before)

        try Data("after".utf8).write(to: file)
        let changed = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(changed != before)
        #expect(try NativePreviewInputSnapshot.capture(roots: [root, first]) == changed)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        #expect(try NativePreviewInputSnapshot.capture(roots: [root]) != changed)

        let later = external.appendingPathComponent("Later.txt")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: later)
        let dangling = try NativePreviewInputSnapshot.capture(roots: [root])

        try Data("created".utf8).write(to: later)
        let created = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(created != dangling)

        try FileManager.default.removeItem(at: later)
        #expect(try NativePreviewInputSnapshot.capture(roots: [root]) == dangling)
    }
}
