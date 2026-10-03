import Foundation

enum ProxyProductBuilder {
    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case buildFailed
        case nativeHostBuildFailed(Int32)

        var description: String {
            switch self {
            case .buildFailed:
                return "swift build failed; run from the repo root and try again"
            case .nativeHostBuildFailed(let status):
                return "scripts/build-native-host.sh failed (status \(status))"
            }
        }
    }

    static func buildReleaseProducts(_ products: [String], in directory: URL, nativeHostBundleURL: URL) throws {
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

        let native = Process()
        native.executableURL = URL(fileURLWithPath: "/bin/bash")
        native.arguments = [directory.appendingPathComponent("scripts/build-native-host.sh").path,
                            "--configuration", "release", "--output", nativeHostBundleURL.path]
        native.currentDirectoryURL = directory
        native.standardOutput = FileHandle.standardOutput
        native.standardError = FileHandle.standardError
        try native.run()
        native.waitUntilExit()
        guard native.terminationStatus == 0 else { throw Error.nativeHostBuildFailed(native.terminationStatus) }
    }
}
