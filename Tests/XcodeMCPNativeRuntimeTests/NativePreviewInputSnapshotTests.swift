import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativePreviewInputSnapshotTests {
    @Test func parallelVerificationRequiresBothSnapshotsToMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.swift")
        let generated = root.appendingPathComponent("Generated.swift")
        try Data("source before".utf8).write(to: source)
        try Data("generated before".utf8).write(to: generated)
        let sourceInputs = try NativePreviewInputSnapshot.capture(roots: [source])
        let generatedInputs = try NativePreviewInputSnapshot.capture(roots: [generated])
        #expect(try NativePreviewInputSnapshot.matchesCurrentFiles(source: sourceInputs, generated: generatedInputs))

        try Data("generated after".utf8).write(to: generated)
        #expect(try sourceInputs.matchesCurrentFiles())
        #expect(try !generatedInputs.matchesCurrentFiles())
        #expect(try !NativePreviewInputSnapshot.matchesCurrentFiles(source: sourceInputs, generated: generatedInputs))

        let currentGenerated = try NativePreviewInputSnapshot.capture(roots: [generated])
        try Data("source after".utf8).write(to: source)
        #expect(try !sourceInputs.matchesCurrentFiles())
        #expect(try currentGenerated.matchesCurrentFiles())
        #expect(try !NativePreviewInputSnapshot.matchesCurrentFiles(source: sourceInputs, generated: currentGenerated))
    }

    @Test func parallelVerificationPreservesSourceResultAndErrorPriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.swift")
        let generated = root.appendingPathComponent("Generated.swift")
        try Data("source before".utf8).write(to: source)
        try Data("generated before".utf8).write(to: generated)
        let sourceInputs = try NativePreviewInputSnapshot.capture(roots: [source])
        let generatedInputs = try NativePreviewInputSnapshot.capture(roots: [generated])

        try Data("source after".utf8).write(to: source)
        try FileManager.default.removeItem(at: generated)
        #expect(try !sourceInputs.matchesCurrentFiles())
        let generatedError: NSError
        do {
            _ = try generatedInputs.matchesCurrentFiles()
            Issue.record("Expected the removed generated input to fail")
            return
        } catch { generatedError = error as NSError }
        let generatedErrorPath = try #require(generatedError.userInfo[NSFilePathErrorKey] as? String)
        #expect(try !NativePreviewInputSnapshot.matchesCurrentFiles(source: sourceInputs, generated: generatedInputs))

        try FileManager.default.removeItem(at: source)
        let sourceError: NSError
        do {
            _ = try sourceInputs.matchesCurrentFiles()
            Issue.record("Expected the removed source input to fail")
            return
        } catch { sourceError = error as NSError }
        let sourceErrorPath = try #require(sourceError.userInfo[NSFilePathErrorKey] as? String)
        #expect(sourceErrorPath != generatedErrorPath)
        do {
            _ = try NativePreviewInputSnapshot.matchesCurrentFiles(source: sourceInputs, generated: generatedInputs)
            Issue.record("Expected the source error when both snapshots fail")
        } catch {
            let received = error as NSError
            #expect(received.domain == sourceError.domain)
            #expect(received.code == sourceError.code)
            #expect(received.userInfo[NSFilePathErrorKey] as? String == sourceErrorPath)
        }

        try Data("source recreated".utf8).write(to: source)
        let currentSource = try NativePreviewInputSnapshot.capture(roots: [source])
        #expect(try currentSource.matchesCurrentFiles())
        do {
            _ = try NativePreviewInputSnapshot.matchesCurrentFiles(source: currentSource, generated: generatedInputs)
            Issue.record("Expected the generated error after the source matches")
        } catch {
            let received = error as NSError
            #expect(received.domain == generatedError.domain)
            #expect(received.code == generatedError.code)
            #expect(received.userInfo[NSFilePathErrorKey] as? String == generatedErrorPath)
        }
    }

    @Test func detectsImmediateChangesToExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("View.swift")
        try Data("before".utf8).write(to: file)
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: [file])
        #expect(try before.matchesCurrentFiles())
        #expect(before.predates(buildStarted))
        #expect(try NativePreviewInputSnapshot.capture(roots: [file]) == before)

        try Data("after".utf8).write(to: file)

        let after = try NativePreviewInputSnapshot.capture(roots: [file])
        #expect(after != before)
        #expect(try !before.matchesCurrentFiles())
        #expect(!after.predates(buildStarted))
    }

    @Test func detectsWritesThroughHardLinksOutsideCapturedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = inputs.appendingPathComponent("Input.h")
        let alias = root.appendingPathComponent("ExternalAlias.h")
        try Data("before".utf8).write(to: input)
        try FileManager.default.linkItem(at: input, to: alias)
        let before = try NativePreviewInputSnapshot.capture(roots: [inputs])
        #expect(try before.matchesCurrentFiles())
        #expect(try NativePreviewInputSnapshot.capture(roots: [inputs]) == before)

        do {
            let writer = try FileHandle(forWritingTo: alias)
            defer { try? writer.close() }
            try writer.write(contentsOf: Data("after!".utf8))
        }

        #expect(try Data(contentsOf: input) == Data("after!".utf8))
        let after = try NativePreviewInputSnapshot.capture(roots: [inputs])
        #expect(after != before)
        #expect(try !before.matchesCurrentFiles())
    }

    @Test func detectsNewAndRemovedResourceDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(try before.matchesCurrentFiles())
        let resources = root.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try Data("resource".utf8).write(to: resources.appendingPathComponent("Label.txt"))
        let added = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(try added.matchesCurrentFiles())
        #expect(added != before)
        #expect(try !before.matchesCurrentFiles())

        try FileManager.default.removeItem(at: resources)

        #expect(try NativePreviewInputSnapshot.capture(roots: [root]) != added)
        #expect(try !added.matchesCurrentFiles())
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
        #expect(try before.matchesCurrentFiles())
        #expect(try NativePreviewInputSnapshot.capture(roots: before.prioritizedRoots([root, first])) == before)

        try Data("after".utf8).write(to: file)
        let changed = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(try changed.matchesCurrentFiles())
        #expect(changed != before)
        #expect(try !before.matchesCurrentFiles())
        #expect(try NativePreviewInputSnapshot.capture(roots: before.prioritizedRoots([root, first])) == changed)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        #expect(try NativePreviewInputSnapshot.capture(roots: [root]) != changed)
        #expect(try !changed.matchesCurrentFiles())

        let later = external.appendingPathComponent("Later.txt")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: later)
        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [root])
        }
        #expect(throws: (any Error).self) { try changed.matchesCurrentFiles() }

        try Data("created".utf8).write(to: later)
        let created = try NativePreviewInputSnapshot.capture(roots: [root])
        #expect(try created.matchesCurrentFiles())
        #expect(created != changed)

        try FileManager.default.removeItem(at: later)
        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [root])
        }
        #expect(throws: (any Error).self) { try created.matchesCurrentFiles() }
    }

    @Test func rejectsRemovedExplicitInputsOutsideCapturedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("External Info.plist")
        try Data("consumed input".utf8).write(to: external)
        let before = try NativePreviewInputSnapshot.capture(roots: [project, external])
        #expect(try before.matchesCurrentFiles())

        try FileManager.default.removeItem(at: external)

        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [project, external])
        }
        #expect(throws: (any Error).self) { try before.matchesCurrentFiles() }
    }

    @Test func tracksMissingLinkerCandidatesAndTransientCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Search", isDirectory: true)
        let candidate = directory.appendingPathComponent("libOptional.tbd")
        let buildStarted = Date()
        let before = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate])
        #expect(try before.matchesCurrentFiles())
        #expect(before.predates(buildStarted))
        #expect(try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate]) == before)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("temporary library".utf8).write(to: candidate)
        try FileManager.default.removeItem(at: directory)

        let after = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate])
        #expect(after != before)
        #expect(try !before.matchesCurrentFiles())
        #expect(!after.predates(buildStarted))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("new library".utf8).write(to: candidate)
        #expect(throws: (any Error).self) {
            try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [candidate])
        }
        #expect(throws: (any Error).self) { try after.matchesCurrentFiles() }
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
        #expect(try before.matchesCurrentFiles())
        let buildStarted = Date()
        #expect(before.predates(buildStarted))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let after = try NativePreviewInputSnapshot.capture(roots: [input])
        #expect(after != before)
        #expect(try !before.matchesCurrentFiles())
        #expect(!after.predates(buildStarted))
    }

    @Test func detectsNewSymbolicLinksInPreviouslyPlainInputAncestors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("Container", isDirectory: true)
        let subdirectory = container.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("input".utf8).write(to: external.appendingPathComponent("Leaf.h"))
        let current = subdirectory.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: external)
        let input = current.appendingPathComponent("Leaf.h")
        let canonicalPath = input.resolvingSymlinksInPath().path
        let before = try NativePreviewInputSnapshot.capture(roots: [input])
        #expect(try before.matchesCurrentFiles())

        let alternate = root.appendingPathComponent("Alt", isDirectory: true)
        try FileManager.default.moveItem(at: container, to: alternate)
        try FileManager.default.createSymbolicLink(at: container, withDestinationURL: alternate)

        #expect(input.resolvingSymlinksInPath().path == canonicalPath)
        #expect(try NativePreviewInputSnapshot.capture(roots: [input]) != before)
        #expect(try !before.matchesCurrentFiles())
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
        #expect(try before.matchesCurrentFiles())
        #expect(before.predates(buildStarted))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let after = try NativePreviewInputSnapshot.capture(roots: [], missingInputs: [missing])
        #expect(after != before)
        #expect(try !before.matchesCurrentFiles())
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
        #expect(try before.matchesCurrentFiles())
        #expect(before.predates(buildStarted))

        try Data("new log".utf8).write(to: logs.appendingPathComponent("Next.log"))
        try Data("updated log".utf8).write(to: log)
        try Data("new product".utf8).write(to: products.appendingPathComponent("App"))
        try Data("generated after build started".utf8).write(to: generated)
        let freshGenerated = derivedData.appendingPathComponent("Fresh.swift")
        try Data("generated".utf8).write(to: freshGenerated)
        let buildCompleted = Date()
        let generatedRoots = [generated, freshGenerated]
        let generatedInputs = try NativePreviewInputSnapshot.capture(roots: generatedRoots)
        #expect(try generatedInputs.matchesCurrentFiles())
        #expect(!generatedInputs.predates(buildStarted))
        #expect(generatedInputs.predates(buildCompleted))
        #expect(try NativePreviewInputSnapshot.capture(roots: generatedRoots) == generatedInputs)

        let afterOutputs = try NativePreviewInputSnapshot.capture(roots: [project], excluding: exclusions)
        #expect(afterOutputs == before)
        #expect(try before.matchesCurrentFiles())
        #expect(afterOutputs.predates(buildStarted))

        let attributes = try FileManager.default.attributesOfItem(atPath: freshGenerated.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        try Data("rewritten".utf8).write(to: freshGenerated)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: freshGenerated.path)
        let afterGenerated = try NativePreviewInputSnapshot.capture(roots: generatedRoots)
        #expect(afterGenerated != generatedInputs)
        #expect(try !generatedInputs.matchesCurrentFiles())
        #expect(!afterGenerated.predates(buildCompleted))
        #expect(try NativePreviewInputSnapshot.capture(roots: [project], excluding: exclusions) == before)
        #expect(try before.matchesCurrentFiles())

        try Data("changed source".utf8).write(to: source)
        let afterSource = try NativePreviewInputSnapshot.capture(roots: [project], excluding: exclusions)
        #expect(afterSource != before)
        #expect(try !before.matchesCurrentFiles())
        #expect(!afterSource.predates(buildStarted))
    }

    @Test func keepsNarrowerExclusionsWhenAnInputReopensTheirParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        let nested = output.appendingPathComponent("Generated", isDirectory: true)
        let sibling = root.appendingPathComponent("OutputExtra", isDirectory: true)
        for directory in [nested, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("OutputAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: output)
        let exclusions: Set<URL> = [output, nested, sibling]
        let expected = Set(exclusions.flatMap { [$0.standardizedFileURL, $0.resolvingSymlinksInPath()] })

        #expect(NativePreviewInputSnapshot.coalescedExclusions(exclusions, roots: [output]) == expected)
        #expect(NativePreviewInputSnapshot.coalescedExclusions(exclusions, roots: [alias]) == expected)
        let withoutReopening = Set([output, sibling].flatMap { [$0.standardizedFileURL, $0.resolvingSymlinksInPath()] })
        #expect(NativePreviewInputSnapshot.coalescedExclusions(exclusions, roots: []) == withoutReopening)
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
        #expect(try before.matchesCurrentFiles())
        #expect(before.predates(buildStarted))

        try Data("new output".utf8).write(to: logs.appendingPathComponent("Next.log"))
        try Data("changed log".utf8).write(to: log)
        try Data("new checkout product".utf8).write(to: checkoutOutputs.appendingPathComponent("Next.o"))
        try Data("changed checkout log".utf8).write(to: checkoutOutputs.appendingPathComponent("Build.log"))
        let afterLogs = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(afterLogs == before)
        #expect(try before.matchesCurrentFiles())
        #expect(afterLogs.predates(buildStarted))

        try Data("changed header".utf8).write(to: header)
        let afterHeader = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(afterHeader != before)
        #expect(try !before.matchesCurrentFiles())
        #expect(!afterHeader.predates(buildStarted))

        try Data("new resource".utf8).write(to: resources.appendingPathComponent("New.txt"))
        let afterResource = try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions)
        #expect(try afterResource.matchesCurrentFiles())
        #expect(afterResource != afterHeader)
        #expect(try !afterHeader.matchesCurrentFiles())

        try Data("new source".utf8).write(to: nestedSources.appendingPathComponent("Added.swift"))
        #expect(try NativePreviewInputSnapshot.capture(roots: roots, excluding: exclusions) != afterResource)
        #expect(try !afterResource.matchesCurrentFiles())
    }

}
