import Foundation
import MachOKit

@safe
@MainActor
enum NativePreviewBinary {
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
