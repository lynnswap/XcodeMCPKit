import Foundation
import MachOKit

@safe
@MainActor
enum NativePreviewBinary {
    static func matches(_ source: URL, _ candidate: URL, architecture: String) throws -> Bool {
        guard let sourceFile = try file(at: source, architecture: architecture),
              let candidateFile = try file(at: candidate, architecture: architecture) else { return false }
        if let sourceUUID = sourceFile.loadCommands.info(of: LoadCommand.uuid)?.uuid,
           let candidateUUID = candidateFile.loadCommands.info(of: LoadCommand.uuid)?.uuid {
            // Signing and thinning can change bytes while preserving the built image's UUID.
            return sourceUUID == candidateUUID
        }
        return try Data(contentsOf: source, options: .mappedIfSafe)
            == Data(contentsOf: candidate, options: .mappedIfSafe)
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
