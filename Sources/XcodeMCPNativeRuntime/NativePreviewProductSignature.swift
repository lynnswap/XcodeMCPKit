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

    init(build: NativePreviewBuild.Result, source: URL, helper: URL, additionalProducts: [URL] = []) throws {
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
        files = try Self.stamps(for: products)
    }

    private static func stamps(for roots: Set<URL>) throws -> [FileStamp] {
        var pending = Array(roots)
        var visited: Set<String> = []
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
                content = Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
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
