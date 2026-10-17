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
            self.path = path
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

    private struct CaptureWork: Sendable {
        var nextRoot = 0
        var snapshots: [NativePreviewInputSnapshot] = []
        var failure: (any Error)?
    }

    private struct ConflictingEntry: Error {
        let path: String
    }

    static func capture(roots: [URL], missingInputs: Set<URL> = []) throws -> Self {
        let workers = min(roots.count, ProcessInfo.processInfo.activeProcessorCount, 4)
        let snapshots: [Self]
        if workers <= 1 { snapshots = [try captureSerial(roots: roots)] }
        else {
            let work = Mutex(CaptureWork())
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while let root = work.withLock({ state -> URL? in
                    guard state.failure == nil, state.nextRoot < roots.count else { return nil }
                    let index = state.nextRoot
                    state.nextRoot += 1
                    return roots[index]
                }) {
                    do {
                        let snapshot = try captureSerial(roots: [root])
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
        let missingPaths = Set(missingInputs.map { $0.standardizedFileURL.path })
        let ordered = (snapshots.flatMap { $0.entries } + (try missingInputAncestors(missingPaths)))
            .sorted { $0.path < $1.path }
        var entries: [Entry] = []
        entries.reserveCapacity(ordered.count)
        for entry in ordered {
            if let existing = entries.last, existing.path == entry.path {
                guard existing == entry else { throw ConflictingEntry(path: entry.path) }
            } else { entries.append(entry) }
        }
        return Self(entries: entries, missingPaths: missingPaths)
    }

    private static func missingInputAncestors(_ paths: Set<String>) throws -> [Entry] {
        var entries: [Entry] = []
        var routes: [URL] = []
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
        for path in paths {
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
        // A negative lookup depends on its nearest existing parent and on every symlink used to reach it.
        // Observe these entries without walking unrelated directory contents.
        var visited: Set<String> = []
        while let route = routes.popLast() {
            guard visited.insert(route.path).inserted else { continue }
            var prefix = URL(filePath: "/", directoryHint: .isDirectory)
            for component in route.pathComponents.dropFirst() {
                prefix.appendPathComponent(component)
                let value = try metadata(prefix.path)
                if value.st_mode & S_IFMT == S_IFLNK {
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: prefix.path)
                    entries.append(Entry(path: prefix.path, value: value, symbolicLinkDestination: destination))
                    let parent = prefix.deletingLastPathComponent()
                    try append(parent.path, metadata(parent.path))
                    routes.append(URL(filePath: destination, relativeTo: parent).absoluteURL.standardizedFileURL)
                }
            }
            let canonical = route.resolvingSymlinksInPath().path
            try append(canonical, metadata(canonical))
        }
        return entries
    }

    private static func captureSerial(roots: [URL]) throws -> Self {
        let fileMetadata = NativePreviewFileMetadata()
        var pending = roots.map { (path: $0.standardizedFileURL.path, isCanonical: false, metadata: Optional<stat>.none) }
        var visited: Set<String> = []
        var expandedDirectories: Set<String> = []
        var entries: [Entry] = []
        while let next = pending.popLast() {
            let path = next.path
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
        return Self(entries: entries.sorted { $0.path < $1.path }, missingPaths: [])
    }
}
