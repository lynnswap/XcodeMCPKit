import Foundation

enum ProxyProductBuilder {
    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case buildFailed

        var description: String {
            switch self {
            case .buildFailed:
                return "swift build failed; run from the repo root and try again"
            }
        }
    }

    static func buildReleaseProducts(_ products: [String], in directory: URL) throws {
        for product in products {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", "build", "-c", "release", "--product", product]
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Error.buildFailed
            }
        }
    }
}
