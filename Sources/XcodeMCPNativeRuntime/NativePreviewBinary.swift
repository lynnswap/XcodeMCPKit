import Foundation
import MachOKit

@safe
@MainActor
enum NativePreviewBinary {
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
        guard case .machO(let file) = try MachOKit.loadFromFile(url: url),
              file.header.cpuType == .arm64 else { return nil }
        return file
    }
}
