import ABIBridge
import ABIBridgeCore
import ABIBridgeCore.Backend
import Foundation

/// Synchronizes a workspace's project containers before a preview build and collects the inputs that certify a reusable build.
@safe
@MainActor
final class NativePreviewProjectInputs {
    private let runtime = ABIRuntime.shared

    private var synchronizedProjects: [ObjectIdentifier: ProjectSynchronization] = [:]

    private final class ProjectSynchronization {
        weak var workspace: AnyObject?
        let inputs: NativePreviewInputSnapshot

        init(workspace: AnyObject, inputs: NativePreviewInputSnapshot) {
            self.workspace = workspace
            self.inputs = inputs
        }
    }

    func synchronizeProjectContainers(in workspace: AnyObject) async throws {
        try Task.checkCancellation()
        synchronizedProjects = synchronizedProjects.filter { $0.value.workspace != nil }
        let identifier = ObjectIdentifier(workspace)
        if let previous = synchronizedProjects[identifier], previous.workspace === workspace,
           let current = try? projectConfigurationSnapshot(in: workspace), current == previous.inputs {
            return
        }
        synchronizedProjects[identifier] = nil
        let synchronizationStartedAt = Date()
        guard let containers = try NativeObjCGetters.object(workspace, selector: "referencedContainers") as? NSSet else {
            throw NativeRuntimeError.unsupportedContract("The native workspace has no referenced containers")
        }
        var updates: [(valid: NativeBoundObjCMethod<Bool>, edited: NativeBoundObjCMethod<Bool>,
                       invalidate: () throws -> Void, queue: OperationQueue)] = []
        var inputFiles: [(invalidate: NativeBoundObjCMethod<Void>, modificationDate: NativeBoundObjCMethod<AnyObject?>)] = []
        func addInputFile(_ filePath: AnyObject) throws {
            let path = runtime.object(filePath)
            inputFiles.append((
                    try path.resolveAndWait(.objc(.method("invalidateFilePath", as: (() -> Void).self))),
                    try path.resolveAndWait(.objc(.method("modificationDate", as: (() -> AnyObject?).self)))
                ))
        }
        for case let container as NSObject in containers.allObjects
            where container !== workspace && container.responds(to: NSSelectorFromString("pbxProject")) {
            let native = runtime.object(container)
            let valid = try native.resolveAndWait(.objc(.method("isValid", as: (() -> Bool).self)))
            guard try unsafe valid.unsafeInvoke() else { continue }
            let edited = try native.resolveAndWait(.objc(.method("containerEditedByUserInUI", as: (() -> Bool).self)))
            guard try unsafe !edited.unsafeInvoke() else { continue }
            let invalidate: () throws -> Void
            if container.responds(to: NSSelectorFromString("_invalidateContainerToDiscardInMemoryRepresentation:")) {
                let method = try native.resolveAndWait(.objc(.method("_invalidateContainerToDiscardInMemoryRepresentation:", as: ((Bool) -> Void).self)))
                invalidate = { try unsafe method.unsafeInvoke(true) }
            } else {
                let method = try native.resolveAndWait(.objc(.method("_invalidateContainerToDiscardInMemoryRepresentation", as: (() -> Void).self)))
                invalidate = { try unsafe method.unsafeInvoke() }
            }
            guard let graph = try NativeObjCGetters.object(container, selector: "objectGraph"),
                  let queue = try NativeObjCGetters.object(graph, selector: "changeQueue") as? OperationQueue else {
                throw NativeRuntimeError.unsupportedContract("A native project container has no model change queue")
            }
            let dataFiles = try native.resolveAndWait(.objc(.method("_containerDataFilePaths", as: (() -> NSArray).self)))
            for filePath in try unsafe dataFiles.unsafeInvoke() { try addInputFile(filePath as AnyObject) }
            updates.append((valid, edited, invalidate, queue))
        }
        guard !updates.isEmpty else { return }
        if let configurationPaths = try configurationFilePaths(in: containers) {
            let paths = configurationPaths.bases.merging(configurationPaths.watched) { existing, _ in existing }
            for filePath in paths.values { try addInputFile(filePath) }
        }
        guard let environment = try NativeObjCGetters.object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.unsupportedContract("The native workspace has no execution environment")
        }
        let disable = try runtime.object(environment).resolveAndWait(
            .objc(.method("disableSubmissionOfBuildOperationsWithReason:", as: ((String) -> Void).self)))
        let enable = try runtime.object(environment).resolveAndWait(.objc(.method("enableSubmissionOfBuildOperationsWithReason:", as: ((String) -> Void).self)))
        typealias Completion = @convention(block) () -> Void
        let cancel = try runtime.object(workspace).resolveAndWait(
            .objc(.method("_cancelOngoingBuildWithCompletionBlockIfNeeded:", as: ((Completion?) -> Bool).self)))
        let reason = "Synchronizing preview project inputs"
        try Task.checkCancellation()
        try unsafe disable.unsafeInvoke(reason)
        let outcome: Swift.Result<Void, any Error>
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let completed: Completion = { continuation.resume() }
                do {
                    // A false result means no build was queued and the callback will not run.
                    if try unsafe !cancel.unsafeInvoke(completed) { continuation.resume() }
                } catch { continuation.resume(throwing: error) }
            }
            try Task.checkCancellation()
            // Replacement containers use these dates; configuration parsers also reuse the vnode's derived cache.
            for file in inputFiles {
                try unsafe file.invalidate.unsafeInvoke()
                _ = try unsafe file.modificationDate.unsafeInvoke()
            }
            var queues: [OperationQueue] = []
            var seen: Set<ObjectIdentifier> = []
            for update in updates {
                if seen.insert(ObjectIdentifier(update.queue)).inserted { queues.append(update.queue) }
                // Invalidating one container can also replace another referenced container.
                guard try unsafe update.valid.unsafeInvoke(), try unsafe !update.edited.unsafeInvoke() else { continue }
                try update.invalidate()
            }
            for queue in queues {
                await withCheckedContinuation { continuation in
                    queue.addBarrierBlock { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            outcome = .success(())
        } catch { outcome = .failure(error) }
        do { try unsafe enable.unsafeInvoke(reason) }
        catch {
            let operation: String
            switch outcome {
            case .success: operation = "Native preview project synchronization completed"
            case .failure(let failure): operation = String(describing: failure)
            }
            throw NativeRuntimeError.invocation("\(operation); failed to resume native build submissions: \(error)")
        }
        try outcome.get()
        // A source edit or invalidated build certificate does not require replacing project models.
        // Only certify settings that were already saved before those models were refreshed.
        if let inputs = try? projectConfigurationSnapshot(in: workspace), inputs.predates(synchronizationStartedAt) {
            synchronizedProjects[identifier] = ProjectSynchronization(workspace: workspace, inputs: inputs)
        }
    }

    private func projectConfigurationSnapshot(in workspace: AnyObject) throws -> NativePreviewInputSnapshot? {
        guard let containers = try NativeObjCGetters.object(workspace, selector: "referencedContainers") as? NSSet,
              let configurationPaths = try configurationFilePaths(in: containers),
              let configurationFiles = trackableConfigurationFiles(configurationPaths) else { return nil }
        var roots = configurationFiles
        var missing: Set<URL> = []
        for case let container as NSObject in containers.allObjects
            where container !== workspace && container.responds(to: NSSelectorFromString("pbxProject")) {
            let dataFiles = try runtime.object(container).resolveAndWait(.objc(.method("_containerDataFilePaths", as: (() -> NSArray).self)))
            for filePath in try unsafe dataFiles.unsafeInvoke() {
                guard let url = try NativeObjCGetters.object(filePath as AnyObject, selector: "fileURL") as? URL,
                      url.isFileURL, url.path.hasPrefix("/") else { return nil }
                if FileManager.default.fileExists(atPath: url.path) { roots.insert(url) }
                else { missing.insert(url) }
            }
        }
        return try NativePreviewInputSnapshot.capture(roots: Array(roots), missingInputs: missing)
    }

    private func configurationFilePaths(in containers: NSSet) throws -> (bases: [URL: AnyObject], watched: [URL: AnyObject])? {
        var baseFiles: [URL: AnyObject] = [:]
        var watchedFiles: [URL: AnyObject] = [:]
        for entry in containers.allObjects {
            guard let container = entry as? NSObject else { return nil }
            guard container.responds(to: NSSelectorFromString("pbxProject")) else { continue }
            guard let project = try NativeObjCGetters.object(container, selector: "pbxProject"),
                  let targets = try NativeObjCGetters.object(project, selector: "targets") as? NSArray else { return nil }
            for owner in [project] + targets.map({ $0 as AnyObject }) {
                guard let list = try NativeObjCGetters.object(owner, selector: "buildConfigurationList"),
                      let configurations = try NativeObjCGetters.object(list, selector: "buildConfigurations") as? NSArray else { return nil }
                for configuration in configurations {
                    let configuration = configuration as AnyObject
                    guard try NativeObjCGetters.object(configuration, selector: "baseConfigurationAnchoredReference") != nil else { continue }
                    guard let reference = try NativeObjCGetters.object(configuration, selector: "resolvedBaseConfigurationReference"),
                          let path = try NativeObjCGetters.object(reference, selector: "resolvedAbsolutePath") as? String,
                          path.hasPrefix("/"),
                          let filePath = try NativeObjCGetters.object(path as NSString, selector: "dvt_absoluteFilePath") else { return nil }
                    baseFiles[URL(filePath: path).standardizedFileURL] = filePath
                    let watched = try unsafe runtime.object(configuration).value(forObjCIvar: "_watchedBaseConfigurationFilePaths", as: NSSet?.self)
                    for filePath in watched?.allObjects ?? [] {
                        guard let url = try NativeObjCGetters.object(filePath as AnyObject, selector: "fileURL") as? URL,
                              url.isFileURL, url.path.hasPrefix("/") else { return nil }
                        watchedFiles[url.standardizedFileURL] = filePath as AnyObject
                    }
                }
            }
        }
        return (baseFiles, watchedFiles)
    }

    private func trackableConfigurationFiles(_ configurationPaths: (bases: [URL: AnyObject], watched: [URL: AnyObject])) -> Set<URL>? {
        let baseFiles = Set(configurationPaths.bases.keys)
        let watchedFiles = Set(configurationPaths.watched.keys)
        let configurationFiles = baseFiles.union(watchedFiles)
        for file in configurationFiles {
            // Optional includes can name paths absent from the native watched set.
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.utf8.contains(0x3f) else { return nil }
            if baseFiles.contains(file), text.utf8.contains(0x23), !watchedFiles.contains(file) { return nil }
        }
        return configurationFiles
    }

    func inputRoots(workspace: AnyObject, build: NativePreviewBuild.Result, source: URL, excluding: Set<URL> = []) throws -> (roots: [URL], missing: Set<URL>)? {
        guard let declaredInputFiles = build.declaredInputFiles,
              let containers = try NativeObjCGetters.object(workspace, selector: "referencedContainers") as? NSSet,
              let configurationPaths = try configurationFilePaths(in: containers),
              let configurationFiles = trackableConfigurationFiles(configurationPaths) else { return nil }
        guard let filePath = try NativeObjCGetters.object(workspace, selector: "representingFilePath"),
              let workspaceURL = try NativeObjCGetters.object(filePath, selector: "fileURL") as? URL else {
            throw NativeRuntimeError.unsupportedContract("The native workspace has no representing file URL")
        }
        // Native builder invalidation owns workspace configuration; these trees also detect disk edits synchronously.
        var roots: Set<URL> = [workspaceURL]
        var missing: Set<URL> = []
        for case let container as NSObject in containers.allObjects
            where container.responds(to: NSSelectorFromString("pbxProject")) {
            let dataFiles = try runtime.object(container).resolveAndWait(.objc(.method("_containerDataFilePaths", as: (() -> NSArray).self)))
            for filePath in try unsafe dataFiles.unsafeInvoke() {
                guard let url = try NativeObjCGetters.object(filePath as AnyObject, selector: "fileURL") as? URL,
                      url.isFileURL, url.path.hasPrefix("/") else { return nil }
                // Native containers include alternate project formats that need not exist on disk.
                if FileManager.default.fileExists(atPath: url.path) { roots.insert(url) }
                else { missing.insert(url) }
            }
        }
        roots.formUnion(configurationFiles)
        roots.formUnion(declaredInputFiles)
        var sources: Set<URL> = [source]
        var pending = build.targets + build.previewRoots
        while let target = pending.popLast() {
            sources.formUnion(target.sourceFiles)
            pending += target.dependencies
        }
        sources = NativePreviewBuildInputs.removingGeneratedPaths(from: sources, generatedPaths: build.generatedInputPaths)
        let sourceDirectories = try Set(sources.map { source in
            guard source.isFileURL, source.path.hasPrefix("/") else {
                throw NativeRuntimeError.unsupportedContract("A native build source has no absolute file URL: \(source)")
            }
            return source.deletingLastPathComponent().standardizedFileURL
        })
        var packageSearches: Set<String> = []
        for sourceDirectory in sourceDirectories {
            roots.insert(sourceDirectory)
            var directory = sourceDirectory
            while packageSearches.insert(directory.path).inserted {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                    roots.insert(directory)
                    break
                }
                let parent = directory.deletingLastPathComponent().standardizedFileURL
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        struct RootFact {
            let url: URL
            let path: String
            let components: [String]
        }
        let unique = Set(roots.map(\.standardizedFileURL))
        let facts: [RootFact] = unique.map {
            RootFact(url: $0, path: $0.path, components: $0.pathComponents)
        }
        let normalized = facts.sorted { left, right in
            if left.components.count == right.components.count { return left.path < right.path }
            return left.components.count < right.components.count
        }
        var exclusionIDs: [[String]: Int] = [:]
        for excluded in excluding.union(build.inputCaptureExclusions) {
            for path in [excluded.standardizedFileURL.pathComponents,
                         excluded.resolvingSymlinksInPath().pathComponents] {
                if exclusionIDs[path] == nil { exclusionIDs[path] = exclusionIDs.count }
            }
        }
        var result: [URL] = []
        var retained: [[String]: [Set<Int>]] = [:]
        for candidate in normalized {
            var candidateExclusions: Set<Int> = []
            for path in [candidate.components, candidate.url.resolvingSymlinksInPath().pathComponents] {
                var prefix: [String] = []
                prefix.reserveCapacity(path.count)
                for component in path {
                    prefix.append(component)
                    if let id = exclusionIDs[prefix] { candidateExclusions.insert(id) }
                }
            }
            var prefix: [String] = []
            prefix.reserveCapacity(candidate.components.count)
            var covered = false
            for component in candidate.components {
                prefix.append(component)
                if let parents = retained[prefix], parents.contains(where: {
                    candidateExclusions.isSubset(of: $0)
                }) {
                    covered = true
                    break
                }
            }
            if !covered {
                result.append(candidate.url)
                retained[candidate.components, default: []].append(candidateExclusions)
            }
        }
        return (result, missing)
    }
}
