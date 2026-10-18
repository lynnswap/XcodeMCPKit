import Darwin
import Dispatch
import Foundation
import Synchronization

struct NativePreviewInputSnapshot: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int
        let symbolicLinkDestination: String?

        init(path: String, value: stat, symbolicLinkDestination: String?) {
            var storedPath = path
            storedPath.makeContiguousUTF8()
            self.path = storedPath
            device = value.st_dev
            inode = value.st_ino
            mode = value.st_mode
            size = value.st_size
            modificationSeconds = value.st_mtimespec.tv_sec
            modificationNanoseconds = value.st_mtimespec.tv_nsec
            changeSeconds = value.st_ctimespec.tv_sec
            changeNanoseconds = value.st_ctimespec.tv_nsec
            self.symbolicLinkDestination = symbolicLinkDestination
        }
    }


    private struct DirectoryVerification: Sendable {
        let path: String
        let includedNames: Set<String>
        let ignoredNames: Set<String>
        let bulkPaths: Set<String>
    }

    private struct InputVerification: Sendable {
        var root: URL?
        var rootPaths: Set<String> = []
        var directories: [DirectoryVerification] = []
        var canonicalAliases: [URL: String] = [:]
        var isComplete = true

        mutating func recordAlias(_ url: URL, canonical: String) {
            if let previous = canonicalAliases.updateValue(canonical, forKey: url), previous != canonical {
                isComplete = false
            }
        }
    }

    private struct CaptureResult: Sendable {
        let entries: [Entry]
        let verification: InputVerification
        let plainAncestors: Set<String>
    }

    private enum VerificationCheck: Sendable {
        case aliases(root: URL?, rootPaths: Set<String>, canonicalAliases: [URL: String])
        case directory(DirectoryVerification)
        case entries([Int])
    }

    private struct VerificationPlan: Sendable {
        let roots: [URL]
        let exclusions: Set<URL>
        let missingInputs: Set<URL>
        let exclusionAliases: [String: Set<String>]
        let entryIndices: [String: Int]
        let plainAncestors: Set<String>
        let checks: [VerificationCheck]?
    }

    private struct VerificationWork: Sendable {
        var matches = true
        var failure: (any Error)?
    }

    private let entries: [Entry]
    private let missingPaths: Set<String>
    private let verification: VerificationPlan

    static func == (lhs: Self, rhs: Self) -> Bool {
        // The verification recipe does not change which filesystem observations are equal.
        lhs.entries == rhs.entries && lhs.missingPaths == rhs.missingPaths
    }

    private typealias CancellationCheck = @Sendable () throws -> Void

    static func matchesCurrentFiles(source: Self, generated: Self) throws -> Bool {
        try matchesCurrentFiles(source: source, generated: generated, checkCancellation: {})
    }

    @concurrent
    static func matchesCurrentFiles(source: Self, generated: Self) async throws -> Bool {
        try await withCancellation { check in
            try matchesCurrentFiles(source: source, generated: generated, checkCancellation: check)
        }
    }

    private static func withCancellation<Output: Sendable>(
        _ operation: @Sendable (CancellationCheck) throws -> Output
    ) async throws -> Output {
        let cancelled = Atomic(false)
        return try await withTaskCancellationHandler {
            let check: CancellationCheck = {
                if cancelled.load(ordering: .relaxed) { throw CancellationError() }
            }
            try Task.checkCancellation()
            do {
                let result = try operation(check)
                try check()
                return result
            } catch {
                try check()
                throw error
            }
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
        }
    }

    private static func matchesCurrentFiles(source: Self, generated: Self,
                                            checkCancellation: CancellationCheck) throws -> Bool {
        try checkCancellation()
        let results = Mutex((source: Result<Bool, any Error>.success(false),
                             generated: Result<Bool, any Error>.success(false)))
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = Result<Bool, any Error> {
                try (index == 0 ? source : generated).matchesCurrentFiles(checkCancellation: checkCancellation)
            }
            results.withLock { state in
                if index == 0 { state.source = result }
                else { state.generated = result }
            }
        }
        try checkCancellation()
        let completed = results.withLock { $0 }
        // Both operations finish before returning; source still determines whether the generated result is used.
        guard try completed.source.get() else { return false }
        return try completed.generated.get()
    }

    func matchesCurrentFiles() throws -> Bool {
        try matchesCurrentFiles(checkCancellation: {})
    }

    private func matchesCurrentFiles(checkCancellation: CancellationCheck) throws -> Bool {
        do {
            if try verifyCurrentFiles(checkCancellation: checkCancellation) { return true }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        return try Self.capture(roots: prioritizedRoots(verification.roots), excluding: verification.exclusions,
            missingInputs: verification.missingInputs, checkCancellation: checkCancellation) == self
    }

    private func verifyCurrentFiles(checkCancellation: CancellationCheck) throws -> Bool {
        try checkCancellation()
        guard let checks = verification.checks,
              try Self.exclusionAliases(verification.exclusions, checkCancellation: checkCancellation) == verification.exclusionAliases else { return false }
        for path in verification.plainAncestors {
            try checkCancellation()
            guard try Self.metadata(path).st_mode & S_IFMT != S_IFLNK else { return false }
        }
        for path in missingPaths {
            try checkCancellation()
            var value = stat()
            if unsafe lstat(path, &value) == 0 { return false }
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
        }
        if checks.count <= 1 {
            for check in checks {
                guard try verify(check, checkCancellation: checkCancellation) else { return false }
            }
            return true
        }
        let work = Mutex(VerificationWork())
        DispatchQueue.concurrentPerform(iterations: checks.count) { index in
            do {
                try checkCancellation()
                if try !verify(checks[index], checkCancellation: checkCancellation) {
                    work.withLock { $0.matches = false }
                }
            } catch {
                work.withLock { if $0.failure == nil { $0.failure = error } }
            }
        }
        try checkCancellation()
        return try work.withLock { state in
            if let failure = state.failure { throw failure }
            return state.matches
        }
    }

    private func verify(_ check: VerificationCheck, checkCancellation: CancellationCheck) throws -> Bool {
        try checkCancellation()
        switch check {
        case .aliases(let root, let rootPaths, let canonicalAliases):
            if let root {
                let standard = root.standardizedFileURL.path
                let canonical = root.resolvingSymlinksInPath().path
                guard Set([standard, canonical]) == rootPaths,
                      canonicalAliases[root] == canonical else { return false }
            }
            for (url, canonical) in canonicalAliases {
                try checkCancellation()
                if url == root { continue }
                guard url.resolvingSymlinksInPath().path == canonical else { return false }
            }
        case .directory(let directory):
            let reader = NativePreviewFileMetadata()
            let children = try reader.directoryEntries(atPath: directory.path, checkCancellation: checkCancellation)
            let prefix = directory.path == "/" ? directory.path : directory.path + "/"
            var names: Set<String> = []
            for child in children {
                try checkCancellation()
                let path = prefix + child.name
                if directory.ignoredNames.contains(child.name) { continue }
                names.insert(child.name)
                if directory.bulkPaths.contains(path) {
                    guard let index = verification.entryIndices[path] else { return false }
                    if let value = child.metadata {
                        guard Entry(path: path, value: value, symbolicLinkDestination: nil) == entries[index] else { return false }
                    } else if try !verifyEntry(index, checkCancellation: checkCancellation) { return false }
                }
            }
            guard names == directory.includedNames else { return false }
        case .entries(let indices):
            for index in indices {
                guard try verifyEntry(index, checkCancellation: checkCancellation) else { return false }
            }
        }
        return true
    }

    private func verifyEntry(_ index: Int, checkCancellation: CancellationCheck) throws -> Bool {
        try checkCancellation()
        let expected = entries[index]
        let value = try Self.metadata(expected.path)
        let destination = value.st_mode & S_IFMT == S_IFLNK
            ? try FileManager.default.destinationOfSymbolicLink(atPath: expected.path) : nil
        return Entry(path: expected.path, value: value, symbolicLinkDestination: destination) == expected
    }

    func predates(_ date: Date) -> Bool {
        let cutoff = date.timeIntervalSince1970
        let seconds = cutoff.rounded(.down)
        // Round down so conversion cannot certify a newer filesystem timestamp.
        let nanoseconds = ((cutoff - seconds) * 1_000_000).rounded(.down) * 1_000
        func isAtOrBefore(_ valueSeconds: Int, _ valueNanoseconds: Int) -> Bool {
            Double(valueSeconds) < seconds || (Double(valueSeconds) == seconds && Double(valueNanoseconds) <= nanoseconds)
        }
        return entries.allSatisfy {
            isAtOrBefore($0.modificationSeconds, $0.modificationNanoseconds)
                && isAtOrBefore($0.changeSeconds, $0.changeNanoseconds)
        }
    }

    func prioritizedRoots(_ roots: [URL]) -> [URL] {
        guard roots.count > 1 else { return roots }
        let weighted = roots.enumerated().map { index, root in
            let path = root.path
            let prefix = path == "/" ? path : path + "/"
            var first = 0
            var end = entries.count
            while first < end {
                let middle = first + (end - first) / 2
                if entries[middle].path < prefix { first = middle + 1 }
                else { end = middle }
            }
            var last = first
            end = entries.count
            while last < end {
                let middle = last + (end - last) / 2
                if entries[middle].path.hasPrefix(prefix) { last = middle + 1 }
                else { end = middle }
            }
            return (root: root, count: last - first, index: index)
        }
        // Prior entries guide scheduling only; the next capture still reads every root.
        return weighted.sorted {
            $0.count == $1.count ? $0.index < $1.index : $0.count > $1.count
        }.map(\.root)
    }

    private enum CaptureInput: Sendable {
        case root(URL)
        case missing(Set<String>)
    }

    private struct CaptureWork: Sendable {
        var nextInput = 0
        var snapshots: [CaptureResult] = []
        var failure: (any Error)?
    }

    private struct ConflictingEntry: Error {
        let path: String
    }

    static func coalescedExclusions(_ exclusions: Set<URL>, roots: [URL]) -> Set<URL> {
        let inputPaths = Set(roots.flatMap {
            [$0.standardizedFileURL.pathComponents, $0.resolvingSymlinksInPath().pathComponents]
        })
        let paths = Set(exclusions.flatMap { [$0.standardizedFileURL, $0.resolvingSymlinksInPath()] })
        let candidates = paths.map { (url: $0, components: $0.pathComponents) }
            .sorted { $0.components.count < $1.components.count }
        var retained: Set<[String]> = []
        var result: Set<URL> = []
        for candidate in candidates {
            var prefix: [String] = []
            prefix.reserveCapacity(candidate.components.count)
            var maxParent = retained.contains(prefix) ? 0 : -1
            var maxInput = inputPaths.contains(prefix) ? 0 : -1
            for component in candidate.components {
                prefix.append(component)
                if retained.contains(prefix) { maxParent = prefix.count }
                if inputPaths.contains(prefix) { maxInput = prefix.count }
            }
            // An explicit input at or below a parent reopens it, so that parent cannot absorb this exclusion.
            if maxParent <= maxInput {
                result.insert(candidate.url)
                retained.insert(candidate.components)
            }
        }
        return result
    }

    static func capture(roots: [URL], excluding: Set<URL> = [], missingInputs: Set<URL> = []) throws -> Self {
        try capture(roots: roots, excluding: excluding, missingInputs: missingInputs, checkCancellation: {})
    }

    @concurrent
    static func capture(roots: [URL], excluding: Set<URL> = [], missingInputs: Set<URL> = []) async throws -> Self {
        try await withCancellation { check in
            try capture(roots: roots, excluding: excluding, missingInputs: missingInputs, checkCancellation: check)
        }
    }

    private static func capture(roots: [URL], excluding: Set<URL>, missingInputs: Set<URL>,
                                checkCancellation: CancellationCheck) throws -> Self {
        try checkCancellation()
        let exclusions = try exclusionAliases(excluding, checkCancellation: checkCancellation)
        let missingPaths = Set(try missingInputs.map {
            try checkCancellation()
            return $0.standardizedFileURL.path
        })
        let missing = missingPaths.sorted()
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let batchSize = max(1, (missing.count + processorCount - 1) / processorCount)
        let inputs = roots.map(CaptureInput.root) + stride(from: 0, to: missing.count, by: batchSize).map {
            CaptureInput.missing(Set(missing[$0..<min(missing.count, $0 + batchSize)]))
        }
        let workers = min(inputs.count, processorCount)
        let snapshots: [CaptureResult]
        if workers <= 1 {
            snapshots = try inputs.map { try capture($0, excluding: exclusions, checkCancellation: checkCancellation) }
        } else {
            let work = Mutex(CaptureWork())
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while let input = work.withLock({ state -> CaptureInput? in
                    guard state.failure == nil, state.nextInput < inputs.count else { return nil }
                    let index = state.nextInput
                    state.nextInput += 1
                    return inputs[index]
                }) {
                    do {
                        try checkCancellation()
                        let snapshot = try capture(input, excluding: exclusions, checkCancellation: checkCancellation)
                        work.withLock { $0.snapshots.append(snapshot) }
                    } catch {
                        work.withLock { if $0.failure == nil { $0.failure = error } }
                        return
                    }
                }
            }
            try checkCancellation()
            snapshots = try work.withLock { state in
                if let failure = state.failure { throw failure }
                return state.snapshots
            }
        }
        try checkCancellation()
        let ordered = snapshots.flatMap { $0.entries }.sorted { $0.path < $1.path }
        var entries: [Entry] = []
        entries.reserveCapacity(ordered.count)
        for entry in ordered {
            try checkCancellation()
            if let existing = entries.last, existing.path == entry.path {
                guard existing == entry else { throw ConflictingEntry(path: entry.path) }
            } else { entries.append(entry) }
        }
        let indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.path, $0.offset) })
        var checks: [VerificationCheck] = []
        var directIndices: Set<Int> = []
        var observedAliases: [URL: String] = [:]
        var plainAncestors: Set<String> = []
        var complete = true
        for captured in snapshots {
            try checkCancellation()
            let input = captured.verification
            complete = complete && input.isComplete
            plainAncestors.formUnion(captured.plainAncestors)
            for (url, canonical) in input.canonicalAliases {
                try checkCancellation()
                if let previous = observedAliases.updateValue(canonical, forKey: url), previous != canonical {
                    complete = false
                }
            }
            let inputIndices = Set(captured.entries.compactMap { indices[$0.path] })
            if inputIndices.count != Set(captured.entries.map(\.path)).count { complete = false }
            var bulkIndices: Set<Int> = []
            for directory in input.directories {
                try checkCancellation()
                let prefix = directory.path == "/" ? directory.path : directory.path + "/"
                if directory.includedNames.contains(where: { indices[prefix + $0] == nil }) { complete = false }
                for path in directory.bulkPaths {
                    try checkCancellation()
                    if let index = indices[path] { bulkIndices.insert(index) }
                    else { complete = false }
                }
                checks.append(.directory(directory))
            }
            checks.append(.aliases(root: input.root, rootPaths: input.rootPaths, canonicalAliases: input.canonicalAliases))
            // A distinct explicit input keeps its direct observation even when another input can use bulk metadata.
            directIndices.formUnion(inputIndices.subtracting(bulkIndices))
        }
        plainAncestors = plainAncestors.filter { path in
            guard let index = indices[path] else { return true }
            if entries[index].mode & S_IFMT == S_IFLNK { complete = false }
            return false
        }
        let direct = directIndices.sorted()
        let directBatchSize = max(1, (direct.count + processorCount - 1) / processorCount)
        for first in stride(from: 0, to: direct.count, by: directBatchSize) {
            checks.append(.entries(Array(direct[first..<min(direct.count, first + directBatchSize)])))
        }
        let plan = VerificationPlan(roots: roots, exclusions: excluding, missingInputs: missingInputs,
            exclusionAliases: exclusions, entryIndices: indices, plainAncestors: plainAncestors,
            checks: complete ? checks : nil)
        try checkCancellation()
        return Self(entries: entries, missingPaths: missingPaths, verification: plan)
    }

    private static func capture(_ input: CaptureInput, excluding: [String: Set<String>],
                                checkCancellation: CancellationCheck) throws -> CaptureResult {
        try checkCancellation()
        switch input {
        case .root(let root):
            return try captureSerial(root: root, excluding: excluding, checkCancellation: checkCancellation)
        case .missing(let paths):
            var verification = InputVerification()
            var plainAncestors: Set<String> = []
            let entries = try inputPathAncestors(missingPaths: paths, routes: [], verification: &verification,
                plainAncestors: &plainAncestors, checkCancellation: checkCancellation)
            return CaptureResult(entries: entries, verification: verification, plainAncestors: plainAncestors)
        }
    }

    private static func isExcluded(_ path: String, excluding: [String: Set<String>], reopenedPaths: Set<String>) -> Bool {
        ancestorPaths(of: path).contains { excluding[$0] != nil && !reopenedPaths.contains($0) }
    }

    private static func exclusionAliases(_ excluding: Set<URL>, checkCancellation: CancellationCheck) throws -> [String: Set<String>] {
        var exclusionAliases: [String: Set<String>] = [:]
        for excluded in excluding {
            try checkCancellation()
            var standardPath = excluded.standardizedFileURL.path
            var canonicalPath = excluded.resolvingSymlinksInPath().path
            standardPath.makeContiguousUTF8()
            canonicalPath.makeContiguousUTF8()
            let paths = Set([standardPath, canonicalPath])
            for path in paths { exclusionAliases[path, default: []].formUnion(paths) }
        }
        return exclusionAliases
    }

    private static func metadata(_ path: String) throws -> stat {
        var value = stat()
        guard unsafe lstat(path, &value) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
        return value
    }
    private static func inputPathAncestors(missingPaths: Set<String>, routes: [URL], verification: inout InputVerification,
                                           plainAncestors: inout Set<String>, checkCancellation: CancellationCheck) throws -> [Entry] {
        var entries: [Entry] = []
        var routes = routes
        func append(_ path: String, _ value: stat) throws {
            try checkCancellation()
            let destination = value.st_mode & S_IFMT == S_IFLNK
                ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
            entries.append(Entry(path: path, value: value, symbolicLinkDestination: destination))
        }
        for path in missingPaths {
            try checkCancellation()
            var ancestor = URL(filePath: path)
            while true {
                try checkCancellation()
                do {
                    let value = try metadata(ancestor.path)
                    guard ancestor.path != path else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSFilePathErrorKey: path])
                    }
                    try append(ancestor.path, value)
                    routes.append(ancestor)
                    break
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                    && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR)) {
                    let parent = ancestor.deletingLastPathComponent()
                    guard parent.path != ancestor.path else { throw error }
                    ancestor = parent
                }
            }
        }
        // Input paths depend on intermediate symlinks; negative lookups also depend on their nearest existing parent.
        // Observe these entries without walking unrelated directory contents.
        var visited: Set<String> = []
        while let route = routes.popLast() {
            try checkCancellation()
            guard visited.insert(route.path).inserted else { continue }
            var prefix = ""
            for component in route.pathComponents.dropFirst() {
                try checkCancellation()
                prefix.append("/")
                prefix.append(component)
                let value = try metadata(prefix)
                if value.st_mode & S_IFMT == S_IFLNK {
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: prefix)
                    entries.append(Entry(path: prefix, value: value, symbolicLinkDestination: destination))
                    let parent = URL(filePath: prefix).deletingLastPathComponent()
                    try append(parent.path, metadata(parent.path))
                    routes.append(URL(filePath: destination, relativeTo: parent).absoluteURL.standardizedFileURL)
                } else { plainAncestors.insert(prefix) }
            }
            let canonical = route.resolvingSymlinksInPath().path
            verification.recordAlias(route, canonical: canonical)
            try append(canonical, metadata(canonical))
        }
        return entries
    }

    private static func ancestorPaths(of path: String) -> [String] {
        var paths: [String] = []
        var prefix = ""
        for component in (path as NSString).pathComponents {
            if component == "/" {
                if prefix.isEmpty { prefix = "/" }
            } else {
                if !prefix.isEmpty, prefix != "/" { prefix.append("/") }
                prefix.append(component)
            }
            paths.append(prefix)
        }
        return paths.reversed()
    }

    private static func captureSerial(root: URL, excluding: [String: Set<String>],
                                      checkCancellation: CancellationCheck) throws -> CaptureResult {
        try checkCancellation()
        let fileMetadata = NativePreviewFileMetadata()
        let standardRootPath = root.standardizedFileURL.path
        let canonicalRootPath = root.resolvingSymlinksInPath().path
        let rootPaths = Set([standardRootPath, canonicalRootPath])
        var verification = InputVerification(root: root, rootPaths: rootPaths)
        var plainAncestors: Set<String> = []
        verification.recordAlias(root, canonical: canonicalRootPath)
        // Explicit inputs and checkouts can live inside a native output directory.
        lazy var reopenedPaths = rootPaths.flatMap { ancestorPaths(of: $0) }.reduce(into: Set<String>()) { paths, ancestor in
            paths.formUnion(excluding[ancestor, default: []])
        }
        func isExcluded(_ path: String) -> Bool {
            if rootPaths.contains(path) { return false }
            return Self.isExcluded(path, excluding: excluding, reopenedPaths: reopenedPaths)
        }
        var pending = [(path: root.standardizedFileURL.path, isCanonical: false, metadata: Optional<stat>.none)]
        var visited: Set<String> = []
        var expandedDirectories: Set<String> = []
        var entries: [Entry] = []
        var routes: [URL] = []
        while let next = pending.popLast() {
            try checkCancellation()
            let path = next.path
            guard !isExcluded(path) else { continue }
            if !next.isCanonical {
                let route = URL(filePath: path)
                let canonical = route.resolvingSymlinksInPath().path
                verification.recordAlias(route, canonical: canonical)
                if isExcluded(canonical) { continue }
            }
            if !next.isCanonical { routes.append(URL(filePath: path)) }
            guard visited.insert(path).inserted else { continue }
            var value: stat
            if let metadata = next.metadata { value = metadata }
            else {
                value = stat()
                guard unsafe lstat(path, &value) == 0 else {
                    let code = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
                }
            }
            let symbolicLinkDestination: String?
            if value.st_mode & S_IFMT == S_IFLNK {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                symbolicLinkDestination = destination
                let destinationURL = URL(filePath: destination, relativeTo: URL(filePath: path).deletingLastPathComponent())
                pending.append((path: destinationURL.absoluteURL.standardizedFileURL.path, isCanonical: false, metadata: nil))
            } else {
                symbolicLinkDestination = nil
                let canonical: String
                if next.isCanonical { canonical = path }
                else {
                    let route = URL(filePath: path)
                    canonical = route.resolvingSymlinksInPath().path
                    verification.recordAlias(route, canonical: canonical)
                }
                if canonical != path { pending.append((path: canonical, isCanonical: true, metadata: nil)) }
                if value.st_mode & S_IFMT == S_IFDIR, expandedDirectories.insert(canonical).inserted {
                    // Names enumerated from canonical directories already have canonical parents.
                    let prefix = canonical == "/" ? canonical : canonical + "/"
                    let children = try fileMetadata.directoryEntries(atPath: canonical, checkCancellation: checkCancellation)
                    var ignoredNames: Set<String> = []
                    let retained = try children.filter {
                        try checkCancellation()
                        let excluded = isExcluded(prefix + $0.name)
                        if excluded { ignoredNames.insert($0.name) }
                        return !excluded
                    }
                    // Also retain absent direct exclusions so their later creation remains ignored.
                    for alias in excluding.keys where alias.hasPrefix(prefix) {
                        try checkCancellation()
                        let name = String(alias.dropFirst(prefix.count))
                        if !name.isEmpty, !name.contains("/"), isExcluded(alias) { ignoredNames.insert(name) }
                    }
                    verification.directories.append(DirectoryVerification(path: canonical,
                        includedNames: Set(retained.map(\.name)), ignoredNames: ignoredNames,
                        bulkPaths: Set(retained.compactMap { $0.metadata == nil ? nil : prefix + $0.name })))
                    pending += try children.map {
                        try checkCancellation()
                        return (path: prefix + $0.name, isCanonical: true, metadata: $0.metadata)
                    }
                }
            }
            entries.append(Entry(path: path, value: value, symbolicLinkDestination: symbolicLinkDestination))
        }
        entries += try inputPathAncestors(missingPaths: [], routes: routes, verification: &verification,
            plainAncestors: &plainAncestors, checkCancellation: checkCancellation)
        return CaptureResult(entries: entries.sorted { $0.path < $1.path }, verification: verification, plainAncestors: plainAncestors)
    }

}
