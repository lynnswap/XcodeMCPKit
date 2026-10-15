import Foundation
import MachOKit

@safe
@MainActor
enum NativePreviewBinary {
    static func isDynamicLibrary(at url: URL, architecture: String) throws -> Bool {
        try dynamicLibrary(at: url, architecture: architecture) != nil
    }

    static func dynamicLibrary(at url: URL, architecture: String) throws -> (identifier: String, dependencies: [String], rpaths: [String])? {
        do {
            guard let image = try file(at: url, architecture: architecture), image.header.fileType == .dylib else { return nil }
            return (image.imagePath, image.dependencies.map(\.dylib.name), image.rpaths)
        }
        catch MachOKitError.invalidMagic { return nil }
    }

    static func matches(_ source: URL, _ candidate: URL, architecture: String) throws -> Bool {
        guard let sourceFile = try file(at: source, architecture: architecture),
              let candidateFile = try file(at: candidate, architecture: architecture) else { return false }
        if let sourceUUID = sourceFile.loadCommands.info(of: LoadCommand.uuid)?.uuid,
           let candidateUUID = candidateFile.loadCommands.info(of: LoadCommand.uuid)?.uuid {
            // Signing and thinning can change bytes while preserving the built image's UUID.
            return sourceUUID == candidateUUID
        }
        return try bytes(of: sourceFile) == bytes(of: candidateFile)
    }

    private static func bytes(of file: MachOFile) throws -> Data {
        let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
        guard file.headerStartOffset != 0 else { return data }
        guard case .fat(let fat) = try MachOKit.loadFromFile(url: file.url),
              let arch = fat.arches.first(where: { Int(exactly: $0.offset) == file.headerStartOffset }),
              let size = Int(exactly: arch.size),
              file.headerStartOffset >= 0, file.headerStartOffset <= data.count,
              size <= data.count - file.headerStartOffset else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.url.path])
        }
        return data.subdata(in: file.headerStartOffset..<(file.headerStartOffset + size))
    }

    static func file(at url: URL, architecture: String) throws -> MachOFile? {
        let cpuType: CPUType
        switch architecture {
        case "arm64": cpuType = .arm64
        case "x86_64": cpuType = .x86_64
        default: return nil
        }
        let files: [MachOFile]
        switch try MachOKit.loadFromFile(url: url) {
        case .machO(let file): files = [file]
        case .fat(let file): files = try file.machOFiles()
        }
        return files.first { $0.header.cpuType == cpuType }
    }
}
