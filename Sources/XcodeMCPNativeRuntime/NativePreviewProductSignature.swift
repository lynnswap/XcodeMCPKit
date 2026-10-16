import CryptoKit
import Darwin
import Foundation

@MainActor
struct NativePreviewProductSignature: Equatable {
    private let configuration: [String]
    private let files: [FileStamp]

    private struct FileStamp: Equatable {
        let path: String
        let mode: UInt16
        let content: Data?
    }

    final class DigestCache {
        private struct Metadata: Equatable {
            let device: dev_t
            let inode: ino_t
            let mode: mode_t
            let size: off_t
            let modificationSeconds: Int
            let modificationNanoseconds: Int
            // Rewrites can preserve the inode, size, and modification time.
            let changeSeconds: Int
            let changeNanoseconds: Int

            init(_ value: stat) {
                device = value.st_dev
                inode = value.st_ino
                mode = value.st_mode
                size = value.st_size
                modificationSeconds = value.st_mtimespec.tv_sec
                modificationNanoseconds = value.st_mtimespec.tv_nsec
                changeSeconds = value.st_ctimespec.tv_sec
                changeNanoseconds = value.st_ctimespec.tv_nsec
            }
        }

        private struct Entry {
            let metadata: Metadata
            let digest: Data
        }

        private var files: [String: Entry] = [:]

        func digest(for url: URL, metadata value: stat) throws -> Data {
            let path = url.standardizedFileURL.path
            let metadata = Metadata(value)
            if let entry = files[path], entry.metadata == metadata { return entry.digest }
            let digest = Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
            files[path] = Entry(metadata: metadata, digest: digest)
            return digest
        }

        func retain(_ paths: Set<String>) {
            files = files.filter { paths.contains($0.key) }
        }
    }

    init(build: NativePreviewBuild.Result, source: URL, helper: URL, digestCache: DigestCache,
         additionalProducts: [URL] = []) throws {
        var configuration = [source.path, build.destinationIdentifier, build.previewDestinationIdentifier,
            build.platformIdentifier ?? "", build.systemVersion ?? ""]
        var products = Set(additionalProducts + [helper])
        var pending = build.targets + build.previewRoots
        while let target = pending.popLast() {
            configuration += [target.moduleName ?? "", target.buildableName, target.sdkRoot, target.sdkVariant ?? "",
                target.architecture, target.linkerWorkingDirectory ?? "", String(target.debugDylibEnabled),
                String(target.isRunnable), String(target.enableAddressSanitizer), String(target.enableThreadSanitizer),
                String(target.enableUndefinedBehaviorSanitizer), String(target.isDynamicPackageProduct),
                String(target.containsPreviewSource), String(target.linkCommandLine.count)] + target.linkCommandLine
            configuration += [String(target.compileCommandLine.count)] + target.compileCommandLine
            configuration += target.rendererEnvironment.keys.sorted().flatMap { [$0, target.rendererEnvironment[$0]!] }
            if let output = target.outputURL {
                products.insert(NativePreviewCorrection.productBundle(containing: output)
                    ?? NativePreviewCorrection.frameworkBundle(containing: output) ?? output)
            }
            products.formUnion(target.resourceURLs)
            pending += target.dependencies
        }
        self.configuration = configuration
        files = try Self.stamps(for: products, digestCache: digestCache)
    }

    private static func stamps(for roots: Set<URL>, digestCache: DigestCache) throws -> [FileStamp] {
        var pending = Array(roots)
        var visited: Set<String> = []
        var regularFiles: Set<String> = []
        defer { digestCache.retain(regularFiles) }
        var result: [FileStamp] = []
        while let url = pending.popLast() {
            let path = url.standardizedFileURL.path
            guard visited.insert(path).inserted else { continue }
            var value = stat()
            if lstat(path, &value) != 0 {
                let code = errno
                // Native build descriptions include optional products that were not built.
                guard code == ENOENT || code == ENOTDIR else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
                }
                result.append(FileStamp(path: path, mode: 0, content: nil))
                continue
            }
            let content: Data?
            switch value.st_mode & S_IFMT {
            case S_IFREG:
                regularFiles.insert(path)
                content = try digestCache.digest(for: url, metadata: value)
            case S_IFLNK:
                content = Data(try FileManager.default.destinationOfSymbolicLink(atPath: path).utf8)
                pending.append(url.resolvingSymlinksInPath())
            case S_IFDIR:
                content = nil
                pending += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            default:
                content = nil
            }
            result.append(FileStamp(path: path, mode: value.st_mode, content: content))
        }
        return result.sorted { $0.path < $1.path }
    }
}
