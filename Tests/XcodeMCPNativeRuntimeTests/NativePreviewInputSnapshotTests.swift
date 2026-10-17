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
    @Test func ignoresBuildOutputsInsideSourceRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let sources = project.appendingPathComponent("Sources", isDirectory: true)
        let derivedData = project.appendingPathComponent("DerivedData", isDirectory: true)
        let logs = derivedData.appendingPathComponent("Logs", isDirectory: true)
        let products = project.appendingPathComponent("CustomProducts", isDirectory: true)
        for directory in [sources, logs, products] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sources.appendingPathComponent("View.swift")
        let generated = sources.appendingPathComponent("Generated.swift")
        let log = logs.appendingPathComponent("Build.log")
        for file in [source, generated, log] { try Data("before".utf8).write(to: file) }
        let exclusions: Set<URL> = [derivedData, products, generated]
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: [project], excluding: exclusions)
        #expect(before.predates(buildStarted))

        try Data("new log".utf8).write(to: logs.appendingPathComponent("Next.log"))
        try Data("updated log".utf8).write(to: log)
        try Data("new product".utf8).write(to: products.appendingPathComponent("App"))
        try Data("generated after build started".utf8).write(to: generated)
        let afterOutputs = try NativePreviewInputSnapshot.capture(roots: [project], excluding: exclusions)
        #expect(afterOutputs == before)
        #expect(afterOutputs.predates(buildStarted))

        try Data("changed source".utf8).write(to: source)
        let afterSource = try NativePreviewInputSnapshot.capture(roots: [project], excluding: exclusions)
        #expect(afterSource != before)
        #expect(!afterSource.predates(buildStarted))
    }

    @Test func preservesExplicitInputsInsideExcludedBuildDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let derivedData = project.appendingPathComponent("DerivedData", isDirectory: true)
        let logs = derivedData.appendingPathComponent("Logs", isDirectory: true)
        let generated = derivedData.appendingPathComponent("Generated", isDirectory: true)
        let resources = derivedData.appendingPathComponent("Resources", isDirectory: true)
        let checkout = derivedData.appendingPathComponent("SourcePackages/checkouts/Library", isDirectory: true)
        let nestedSources = checkout.appendingPathComponent("Sources/Feature", isDirectory: true)
        let checkoutOutputs = checkout.appendingPathComponent(".build", isDirectory: true)
        for directory in [logs, generated, resources, nestedSources, checkoutOutputs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let header = generated.appendingPathComponent("Input.h")
        let log = logs.appendingPathComponent("Build.log")
        for file in [header, log, resources.appendingPathComponent("Label.txt"),
                     nestedSources.appendingPathComponent("Existing.swift"), checkoutOutputs.appendingPathComponent("Build.log")] {
            try Data("before".utf8).write(to: file)
        }
        let alias = project.appendingPathComponent("Headers")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: generated)
        let input = alias.appendingPathComponent("Input.h")
        let roots = [project, input, resources, checkout]
        let exclusions = NativePreviewInputSnapshot.coalescedExclusions([derivedData, checkoutOutputs], roots: roots)
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(before.predates(buildStarted))

        try Data("new output".utf8).write(to: logs.appendingPathComponent("Next.log"))
        try Data("changed log".utf8).write(to: log)
        try Data("new checkout product".utf8).write(to: checkoutOutputs.appendingPathComponent("Next.o"))
        try Data("changed checkout log".utf8).write(to: checkoutOutputs.appendingPathComponent("Build.log"))
        let afterLogs = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(afterLogs == before)
        #expect(afterLogs.predates(buildStarted))

        try Data("changed header".utf8).write(to: header)
        let afterHeader = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(afterHeader != before)
        #expect(!afterHeader.predates(buildStarted))

        try Data("new resource".utf8).write(to: resources.appendingPathComponent("New.txt"))
        let afterResource = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(afterResource != afterHeader)

        try Data("new source".utf8).write(to: nestedSources.appendingPathComponent("Added.swift"))
        #expect(try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions) != afterResource)
    }

}
