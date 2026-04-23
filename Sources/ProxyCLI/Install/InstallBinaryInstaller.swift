import Foundation

package enum InstallBinaryInstaller {
    package static func install(
        options: InstallOptions,
        executableURL: URL,
        binaryNames: [String],
        fileManager: FileManager = .default,
        buildProducts: ([String], URL) throws -> Void,
        stdout: (String) -> Void
    ) throws {
        let baseURL = executableURL.deletingLastPathComponent()
        let binDir = XcodeMCPProxyInstallCommand.resolveBinDir(
            prefix: options.prefix,
            bindir: options.bindir
        )

        if options.dryRun {
            stdout("Would create: \(binDir.path)")
            for name in binaryNames {
                stdout("Would install: \(binDir.appendingPathComponent(name).path)")
            }
            return
        }

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        if let repoRoot = repositoryRoot(from: executableURL),
            fileManager.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path)
        {
            try buildProducts(binaryNames, repoRoot)
        }

        for name in binaryNames {
            let sourceURL = baseURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw InstallCommandError.message(
                    "\(name) not found next to installer (run with `swift run -c release` from the repo root)"
                )
            }

            let destinationURL = binDir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destinationURL.path
            )
            stdout("Installed \(name) to \(destinationURL.path)")
        }
    }

    package static func repositoryRoot(from executableURL: URL) -> URL? {
        var current = executableURL
        while current.path != "/" {
            if current.lastPathComponent == ".build" {
                return current.deletingLastPathComponent()
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    package static func buildProducts(_ products: [String], in directory: URL) throws {
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
                throw InstallCommandError.message(
                    "swift build failed; run from the repo root and try again"
                )
            }
        }
    }
}
