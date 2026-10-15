import Foundation
import MachOKit

@safe
@MainActor
enum NativePreviewBinary {
    static func isDynamicLibrary(at url: URL) throws -> Bool {
        try dynamicLibrary(at: url) != nil
    }

    static func dynamicLibrary(at url: URL) throws -> (identifier: String, dependencies: [String])? {
        do {
            guard let file = try arm64File(at: url), file.header.fileType == .dylib else { return nil }
            return (file.imagePath, file.dependencies.map(\.dylib.name))
        }
        catch MachOKitError.invalidMagic { return nil }
    }

    static func matches(_ source: URL, _ candidate: URL) throws -> Bool {
        guard let sourceFile = try arm64File(at: source),
              let candidateFile = try arm64File(at: candidate) else { return false }
        if let sourceUUID = sourceFile.loadCommands.info(of: LoadCommand.uuid)?.uuid,
           let candidateUUID = candidateFile.loadCommands.info(of: LoadCommand.uuid)?.uuid {
            // Signing and thinning can change bytes while preserving the built image's UUID.
            return sourceUUID == candidateUUID
        }
        return try Data(contentsOf: source, options: .mappedIfSafe)
            == Data(contentsOf: candidate, options: .mappedIfSafe)
    }

    private static func arm64File(at url: URL) throws -> MachOFile? {
        let files: [MachOFile]
        switch try MachOKit.loadFromFile(url: url) {
        case .machO(let file): files = [file]
        case .fat(let file): files = try file.machOFiles()
        }
        return files.first { $0.header.cpuType == .arm64 }
    }
}
