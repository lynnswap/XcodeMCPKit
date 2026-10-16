import Foundation
import MachOKit

@safe
@MainActor
enum NativePreviewBinary {
    struct PreviewSymbols: Sendable {
        let registryNames: [String]
        let programRootNames: [String]
    }

    static func previewSymbols(in libraries: [URL]) throws -> PreviewSymbols {
        var registries: Set<String> = []
        var roots: Set<String> = []
        let mainSuffix = "5$mainyyFZ"
        for library in libraries {
            guard let image = try file(at: library) else {
                throw NativeRuntimeError.unsupportedContract("The preview library has no arm64 Mach-O image: \(library.path)")
            }
            guard let symbols = image.symbols64 else { continue }
            for symbol in symbols {
                guard symbol.nlist.flags?.stab == nil else { continue }
                let name = symbol.name
                guard name.hasPrefix("_$s") else { continue }
                if name.hasSuffix("VMn"), name.contains("fMu_") {
                    registries.insert(String(name.dropFirst(3).dropLast(2)))
                }
                if name.hasSuffix(mainSuffix), let type = symbol.nlist.flags?.type,
                   type != .undf, type != .pbud {
                    roots.insert(String(name.dropFirst(3).dropLast(mainSuffix.count)))
                }
            }
        }
        return PreviewSymbols(registryNames: registries.sorted(), programRootNames: roots.sorted())
    }

    static func isStaticArchive(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 8) == Data("!<arch>\n".utf8)
    }

    static func isStaticLibrary(at url: URL) throws -> Bool {
        try isStaticArchive(at: url) || file(at: url)?.header.fileType == .object
    }

    static func isDynamicLibrary(at url: URL) throws -> Bool {
        try dynamicLibrary(at: url) != nil
    }

    static func dynamicLibrary(at url: URL) throws -> (identifier: String, dependencies: [String], rpaths: [String])? {
        do {
            guard let image = try file(at: url), image.header.fileType == .dylib else { return nil }
            return (image.imagePath, image.dependencies.map(\.dylib.name), image.rpaths)
        }
        catch MachOKitError.invalidMagic { return nil }
    }

    static func matches(_ source: URL, _ candidate: URL) throws -> Bool {
        guard let sourceFile = try file(at: source),
              let candidateFile = try file(at: candidate) else { return false }
        if let sourceUUID = sourceFile.loadCommands.info(of: LoadCommand.uuid)?.uuid,
           let candidateUUID = candidateFile.loadCommands.info(of: LoadCommand.uuid)?.uuid {
            // Signing can change bytes while preserving the built image's UUID.
            return sourceUUID == candidateUUID
        }
        return try Data(contentsOf: source, options: .mappedIfSafe) == Data(contentsOf: candidate, options: .mappedIfSafe)
    }

    static func file(at url: URL) throws -> MachOFile? {
        // Linker operands include auxiliary files; MachOKit's magic read assumes four available bytes.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: MemoryLayout<UInt32>.size), data.count == MemoryLayout<UInt32>.size,
              let magic = data.withUnsafeBytes({ unsafe Magic(rawValue: $0.loadUnaligned(as: UInt32.self)) }),
              magic.is64BitMach || magic.isFat else { return nil }
        let file: MachOFile
        switch try MachOKit.loadFromFile(url: url) {
        case .machO(let image): file = image
        case .fat(let universal):
            let architectures = universal.arches
            guard let architecture = architectures.first(where: { $0.cpuSubType == .arm64(.arm64_all) })
                ?? architectures.first(where: { $0.cpuType == .arm64 }) else { return nil }
            // Universal containers can hold archive slices as well as Mach-O images.
            try handle.seek(toOffset: UInt64(architecture.offset))
            guard let data = try handle.read(upToCount: MemoryLayout<UInt32>.size), data.count == MemoryLayout<UInt32>.size,
                  data.withUnsafeBytes({ unsafe Magic(rawValue: $0.loadUnaligned(as: UInt32.self))?.is64BitMach }) == true else { return nil }
            file = try MachOFile(url: url, headerStartOffset: Int(architecture.offset))
        }
        guard file.header.cpuType == .arm64 else { return nil }
        return file
    }
}
