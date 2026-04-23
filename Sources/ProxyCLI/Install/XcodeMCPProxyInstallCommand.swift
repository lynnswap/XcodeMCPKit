import Foundation

package struct InstallOptions {
    package var prefix: String?
    package var bindir: String?
    package var dryRun: Bool
    package var showHelp: Bool

    package init(prefix: String?, bindir: String?, dryRun: Bool, showHelp: Bool = false) {
        self.prefix = prefix
        self.bindir = bindir
        self.dryRun = dryRun
        self.showHelp = showHelp
    }
}

package struct InstallCommandInvocation {
    package var showHelp = false
    package var showVersion = false
}

package enum InstallCommandError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

package struct XcodeMCPProxyInstallCommand {
    package struct Dependencies {
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var executableURL: () -> URL?
        package var buildProducts: ([String], URL) throws -> Void

        package init(
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            executableURL: @escaping () -> URL?,
            buildProducts: @escaping ([String], URL) throws -> Void
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.executableURL = executableURL
            self.buildProducts = buildProducts
        }

        package static var live: Self {
            Self(
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                executableURL: { Bundle.main.executableURL },
                buildProducts: XcodeMCPProxyInstallCommand.buildProducts
            )
        }
    }

    package static let binaryNames = [
        "xcode-mcp-proxy",
        "xcode-mcp-proxy-server",
    ]

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) -> Int32 {
        InstallCommandRuntime(dependencies: dependencies).execute(
            args: args,
            environment: environment
        )
    }
    package static func install(
        options: InstallOptions,
        executableURL: URL,
        fileManager: FileManager = .default,
        buildProducts: ([String], URL) throws -> Void,
        stdout: (String) -> Void
    ) throws {
        try InstallBinaryInstaller.install(
            options: options,
            executableURL: executableURL,
            binaryNames: binaryNames,
            fileManager: fileManager,
            buildProducts: buildProducts,
            stdout: stdout
        )
    }

    package static func repositoryRoot(from executableURL: URL) -> URL? {
        InstallBinaryInstaller.repositoryRoot(from: executableURL)
    }

    private static func buildProducts(_ products: [String], in directory: URL) throws {
        try InstallBinaryInstaller.buildProducts(products, in: directory)
    }
}
