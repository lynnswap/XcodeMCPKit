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

    private let entries: [Entry]
    private let missingPaths: Set<String>

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
        var snapshots: [NativePreviewInputSnapshot] = []
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
        var exclusionAliases: [String: Set<String>] = [:]
        for excluded in excluding {
            var standardPath = excluded.standardizedFileURL.path
            var canonicalPath = excluded.resolvingSymlinksInPath().path
            standardPath.makeContiguousUTF8()
            canonicalPath.makeContiguousUTF8()
            let paths = Set([standardPath, canonicalPath])
            for path in paths { exclusionAliases[path, default: []].formUnion(paths) }
        }
        let exclusions = exclusionAliases
        let missingPaths = Set(missingInputs.map { $0.standardizedFileURL.path })
        let missing = missingPaths.sorted()
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let batchSize = max(1, (missing.count + processorCount - 1) / processorCount)
        let inputs = roots.map(CaptureInput.root) + stride(from: 0, to: missing.count, by: batchSize).map {
            CaptureInput.missing(Set(missing[$0..<min(missing.count, $0 + batchSize)]))
        }
        let workers = min(inputs.count, processorCount)
        let snapshots: [Self]
        if workers <= 1 { snapshots = try inputs.map { try capture($0, excluding: exclusions) } }
        else {
            let work = Mutex(CaptureWork())
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while let input = work.withLock({ state -> CaptureInput? in
                    guard state.failure == nil, state.nextInput < inputs.count else { return nil }
                    let index = state.nextInput
                    state.nextInput += 1
                    return inputs[index]
                }) {
                    do {
                        let snapshot = try capture(input, excluding: exclusions)
                        work.withLock { $0.snapshots.append(snapshot) }
                    } catch {
                        work.withLock { if $0.failure == nil { $0.failure = error } }
                        return
                    }
                }
            }
            snapshots = try work.withLock { state in
                if let failure = state.failure { throw failure }
                return state.snapshots
            }
        }
        let ordered = snapshots.flatMap { $0.entries }.sorted { $0.path < $1.path }
        var entries: [Entry] = []
        entries.reserveCapacity(ordered.count)
        for entry in ordered {
            if let existing = entries.last, existing.path == entry.path {
                guard existing == entry else { throw ConflictingEntry(path: entry.path) }
            } else { entries.append(entry) }
        }
        return Self(entries: entries, missingPaths: missingPaths)
    }

    private static func capture(_ input: CaptureInput, excluding: [String: Set<String>]) throws -> Self {
        switch input {
        case .root(let root):
            return try captureSerial(root: root, excluding: excluding)
        case .missing(let paths):
            return Self(entries: try inputPathAncestors(missingPaths: paths, routes: []), missingPaths: [])
        }
    }

    private static func inputPathAncestors(missingPaths: Set<String>, routes: [URL]) throws -> [Entry] {
        var entries: [Entry] = []
        var routes = routes
        func metadata(_ path: String) throws -> stat {
            var value = stat()
            guard unsafe lstat(path, &value) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
            return value
        }
        func append(_ path: String, _ value: stat) throws {
            let destination = value.st_mode & S_IFMT == S_IFLNK
                ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
            entries.append(Entry(path: path, value: value, symbolicLinkDestination: destination))
        }
        for path in missingPaths {
            var ancestor = URL(filePath: path)
            while true {
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
            guard visited.insert(route.path).inserted else { continue }
            var prefix = ""
            for component in route.pathComponents.dropFirst() {
                prefix.append("/")
                prefix.append(component)
                let value = try metadata(prefix)
                if value.st_mode & S_IFMT == S_IFLNK {
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: prefix)
                    entries.append(Entry(path: prefix, value: value, symbolicLinkDestination: destination))
                    let parent = URL(filePath: prefix).deletingLastPathComponent()
                    try append(parent.path, metadata(parent.path))
                    routes.append(URL(filePath: destination, relativeTo: parent).absoluteURL.standardizedFileURL)
                }
            }
            let canonical = route.resolvingSymlinksInPath().path
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

    private static func captureSerial(root: URL, excluding: [String: Set<String>]) throws -> Self {
        let fileMetadata = NativePreviewFileMetadata()
        let rootPaths = Set([root.standardizedFileURL.path, root.resolvingSymlinksInPath().path])
        // Explicit inputs and checkouts can live inside a native output directory.
        lazy var reopenedPaths = rootPaths.flatMap { ancestorPaths(of: $0) }.reduce(into: Set<String>()) { paths, ancestor in
            paths.formUnion(excluding[ancestor, default: []])
        }
        func isExcluded(_ path: String) -> Bool {
            if rootPaths.contains(path) { return false }
            return ancestorPaths(of: path).contains { excluding[$0] != nil && !reopenedPaths.contains($0) }
        }
        var pending = [(path: root.standardizedFileURL.path, isCanonical: false, metadata: Optional<stat>.none)]
        var visited: Set<String> = []
        var expandedDirectories: Set<String> = []
        var entries: [Entry] = []
        var routes: [URL] = []
        while let next = pending.popLast() {
            let path = next.path
            guard !isExcluded(path) else { continue }
            if !next.isCanonical, isExcluded(URL(filePath: path).resolvingSymlinksInPath().path) { continue }
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
                let canonical = next.isCanonical ? path : URL(filePath: path).resolvingSymlinksInPath().path
                if canonical != path { pending.append((path: canonical, isCanonical: true, metadata: nil)) }
                if value.st_mode & S_IFMT == S_IFDIR, expandedDirectories.insert(canonical).inserted {
                    // Names enumerated from canonical directories already have canonical parents.
                    let prefix = canonical == "/" ? canonical : canonical + "/"
                    pending += try fileMetadata.directoryEntries(atPath: canonical).map {
                        (path: prefix + $0.name, isCanonical: true, metadata: $0.metadata)
                    }
                }
            }
            entries.append(Entry(path: path, value: value, symbolicLinkDestination: symbolicLinkDestination))
        }
        entries += try inputPathAncestors(missingPaths: [], routes: routes)
        return Self(entries: entries.sorted { $0.path < $1.path }, missingPaths: [])
    }

}
