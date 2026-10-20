import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Product inputs and contents of a staged preview. Content digests are computed off the main
/// actor, which also runs Xcode's workspace models.
struct NativePreviewProductSignature: Equatable, Sendable {
    private let configuration: [String]
    private let products: Set<URL>
    private let files: [FileStamp]

    private struct FileStamp: Equatable, Sendable {
        let path: String
        let mode: UInt16
        let content: Data?
    }

    final class DigestCache: Sendable {
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

        private let files = Mutex<[String: Entry]>([:])

        func digest(for path: String, metadata value: stat) throws -> Data {
            let metadata = Metadata(value)
            if let entry = files.withLock({ $0[path] }), entry.metadata == metadata { return entry.digest }
            let url = URL(filePath: path, directoryHint: .notDirectory)
            let digest = Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
            files.withLock { $0[path] = Entry(metadata: metadata, digest: digest) }
            return digest
        }

        func retain(_ paths: Set<String>) {
            files.withLock { $0 = $0.filter { paths.contains($0.key) } }
        }
    }

    private init(configuration: [String], products: Set<URL>, files: [FileStamp]) {
        self.configuration = configuration
        self.products = products
        self.files = files
    }

    @MainActor
    static func make(build: NativePreviewBuild.Result, source: URL, helper: URL, digestCache: DigestCache,
                     additionalProducts: [URL] = []) async throws -> Self {
        var configuration = [source.path, build.destinationIdentifier, build.previewDestinationIdentifier,
            build.platformIdentifier ?? "", build.systemVersion ?? ""]
        func targetConfiguration(_ target: NativePreviewBuild.Target) -> [String] {
            var result = [target.moduleName ?? "", target.buildableName, target.sdkRoot, target.sdkVariant ?? "",
                target.architecture, target.linkerWorkingDirectory ?? "", String(target.debugDylibEnabled),
                String(target.isRunnable), String(target.enableAddressSanitizer), String(target.enableThreadSanitizer),
                String(target.enableUndefinedBehaviorSanitizer), String(target.isDynamicPackageProduct),
                String(target.containsPreviewSource), String(target.linkCommandLine.count)] + target.linkCommandLine
            result += [String(target.compileCommandLine.count)] + target.compileCommandLine
            result += target.rendererEnvironment.keys.sorted().flatMap { [$0, target.rendererEnvironment[$0]!] }
            return result + target.dependencies.reversed().flatMap { targetConfiguration($0) }
        }
        // Native scheme buildables come from an unordered set; dependency and command order remain significant.
        for targets in [build.targets, build.previewRoots] {
            configuration += targets.map { targetConfiguration($0) }.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }
        }
        var products = Set(additionalProducts + [helper])
        products.formUnion(build.inputProducts)
        var pending = build.targets + build.previewRoots
        while let target = pending.popLast() {
            if let output = target.outputURL {
                products.insert(NativePreviewCorrection.productBundle(containing: output)
                    ?? NativePreviewCorrection.frameworkBundle(containing: output) ?? output)
            }
            products.formUnion(target.resourceURLs)
            pending += target.dependencies
        }
        return Self(configuration: configuration, products: products,
                    files: try await stamps(for: products, digestCache: digestCache))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.files == rhs.files
    }

    func matchesCurrentFiles(digestCache: DigestCache) async throws -> Bool {
        files == (try await Self.stamps(for: products, digestCache: digestCache))
    }

    @concurrent
    private static func stamps(for roots: Set<URL>, digestCache: DigestCache) async throws -> [FileStamp] {
        let fileMetadata = NativePreviewFileMetadata()
        var pending = roots.map { (path: $0.standardizedFileURL.path, metadata: Optional<stat>.none) }
        var visited: Set<String> = []
        var regularFiles: Set<String> = []
        defer { digestCache.retain(regularFiles) }
        var result: [FileStamp] = []
        while let next = pending.popLast() {
            let path = next.path
            guard visited.insert(path).inserted else { continue }
            var value: stat
            if let metadata = next.metadata { value = metadata }
            else {
                value = stat()
                if unsafe lstat(path, &value) != 0 {
                    let code = errno
                    // Native build descriptions include optional products that were not built.
                    guard code == ENOENT || code == ENOTDIR else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
                    }
                    result.append(FileStamp(path: path, mode: 0, content: nil))
                    continue
                }
            }
            let content: Data?
            switch value.st_mode & S_IFMT {
            case S_IFREG:
                regularFiles.insert(path)
                content = try digestCache.digest(for: path, metadata: value)
            case S_IFLNK:
                content = Data(try FileManager.default.destinationOfSymbolicLink(atPath: path).utf8)
                pending.append((path: URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path, metadata: nil))
            case S_IFDIR:
                content = nil
                let prefix = path.hasSuffix("/") ? path : path + "/"
                pending += try fileMetadata.directoryEntries(atPath: path).map { (path: prefix + $0.name, metadata: $0.metadata) }
            default:
                content = nil
            }
            result.append(FileStamp(path: path, mode: value.st_mode, content: content))
        }
        return result.sorted { $0.path < $1.path }
    }
}
