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

    static func capture(roots: [URL]) throws -> Self {
        let workers = min(roots.count, ProcessInfo.processInfo.activeProcessorCount, 4)
        guard workers > 1 else { return try captureSerial(roots: roots) }
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
        let snapshots = try work.withLock { state in
            if let failure = state.failure { throw failure }
            return state.snapshots
        }
        let ordered = snapshots.flatMap { $0.entries }.sorted { $0.path < $1.path }
        var entries: [Entry] = []
        entries.reserveCapacity(ordered.count)
        for entry in ordered {
            if let existing = entries.last, existing.path == entry.path {
                guard existing == entry else { throw ConflictingEntry(path: entry.path) }
            } else { entries.append(entry) }
        }
        return Self(entries: entries)
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
                    if code == ENOENT || code == ENOTDIR { continue }
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
        return Self(entries: entries.sorted { $0.path < $1.path })
    }
}
