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
        #expect(try NativePreviewInputSnapshot.capture(roots: before.prioritizedRoots([root, first])) == before)

        try Data("after".utf8).write(to: file)
        let changed = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(changed != before)
        #expect(try NativePreviewInputSnapshot.capture(roots: before.prioritizedRoots([root, first])) == changed)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        #expect(try NativePreviewInputSnapshot.capture(roots: [root]) != changed)

        let later = external.appendingPathComponent("Later.txt")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: later)
        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [root])
        }

        try Data("created".utf8).write(to: later)
        let created = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(created != changed)

        try FileManager.default.removeItem(at: later)
        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [root])
        }
    }

    @Test func rejectsRemovedExplicitInputsOutsideCapturedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("External Info.plist")
        try Data("consumed input".utf8).write(to: external)

        try FileManager.default.removeItem(at: external)

        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [project, external])
        }
    }

    @Test func tracksMissingLinkerCandidatesAndTransientCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Search", isDirectory: true)
        let candidate = directory.appendingPathComponent("libOptional.tbd")
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate])
        #expect(before.predates(buildStarted))
        #expect(try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate]) == before)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("temporary library".utf8).write(to: candidate)
        try FileManager.default.removeItem(at: directory)

        let after = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate])
        #expect(after != before)
        #expect(!after.predates(buildStarted))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("new library".utf8).write(to: candidate)
        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate])
        }
    }

    @Test func requiredInputTracksIntermediateSymbolicLinkRetargeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first.appendingPathComponent("Subdir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("Subdir"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first input".utf8).write(to: first.appendingPathComponent("Subdir/Leaf.h"))
        try Data("second input".utf8).write(to: second.appendingPathComponent("Subdir/Leaf.h"))
        let link = root.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let input = link.appendingPathComponent("Subdir/Leaf.h")
        let before = try NativePreviewInputSnapshot.capture(roots: [input])
        let buildStarted = Date()
        #expect(before.predates(buildStarted))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let after = try NativePreviewInputSnapshot.capture(roots: [input])
        #expect(after != before)
        #expect(!after.predates(buildStarted))
    }

    @Test func missingLookupTracksIntermediateSymbolicLinkRetargeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first.appendingPathComponent("Subdir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("Subdir"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Search")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let missing = link.appendingPathComponent("Subdir/libOptional.tbd")
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [missing])
        #expect(before.predates(buildStarted))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let after = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [missing])
        #expect(after != before)
        #expect(!after.predates(buildStarted))
    }
}
