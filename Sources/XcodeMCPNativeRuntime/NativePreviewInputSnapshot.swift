import Darwin
import Foundation

struct NativePreviewInputSnapshot: Equatable {
    private struct Entry: Equatable {
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

    static func capture(roots: [URL]) throws -> Self {
        var pending = roots
        var visited: Set<String> = []
        var expandedDirectories: Set<String> = []
        var entries: [Entry] = []
        while let next = pending.popLast() {
            let url = next.standardizedFileURL
            let path = url.path
            guard visited.insert(path).inserted else { continue }
            var value = stat()
            guard lstat(path, &value) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
            let symbolicLinkDestination: String?
            if value.st_mode & S_IFMT == S_IFLNK {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                symbolicLinkDestination = destination
                pending.append(URL(filePath: destination, relativeTo: url.deletingLastPathComponent()).absoluteURL)
            } else {
                symbolicLinkDestination = nil
                let canonical = url.resolvingSymlinksInPath()
                if canonical.path != path { pending.append(canonical) }
                if value.st_mode & S_IFMT == S_IFDIR, expandedDirectories.insert(canonical.path).inserted {
                    pending += try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil)
                }
            }
            entries.append(Entry(path: path, value: value, symbolicLinkDestination: symbolicLinkDestination))
        }
        return Self(entries: entries.sorted { $0.path < $1.path })
    }
}
