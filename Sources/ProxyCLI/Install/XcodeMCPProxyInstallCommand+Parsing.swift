import Foundation

extension XcodeMCPProxyInstallCommand {
    package static func scanInvocation(_ args: [String]) -> InstallCommandInvocation {
        let scan = ProxyCLIInvocationScanner.scanInstall(args)
        var invocation = InstallCommandInvocation()
        invocation.showHelp = scan.showHelp
        invocation.showVersion = scan.showVersion
        return invocation
    }

    package static func usage() -> String {
        """
        Usage:
          xcode-mcp-proxy-install [--bindir path] [--prefix path] [--dry-run]

        Options:
          --bindir path   Install to this directory (overrides --prefix)
          --prefix path   Install to <prefix>/bin (default: ~/.local)
          --dry-run       Print actions without copying files
          --version       Show version
          -h, --help      Show this help

        Examples:
          swift run -c release xcode-mcp-proxy-install
          swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
        """
    }

    package static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    package static func parseOptions(
        _ args: [String],
        environment: [String: String]
    ) throws -> InstallOptions {
        var options = InstallOptions(
            prefix: environment["PREFIX"],
            bindir: environment["BINDIR"],
            dryRun: false
        )

        var cursor = CLIArgumentCursor(args: args)
        while let arg = cursor.current {
            switch arg {
            case "-h", "--help":
                options.showHelp = true
                cursor.advance()
            case "--prefix":
                options.prefix = try cursor.requiredValue(
                    for: arg,
                    error: { InstallCommandError.message("\($0) requires a value") }
                )
            case "--bindir":
                options.bindir = try cursor.requiredValue(
                    for: arg,
                    error: { InstallCommandError.message("\($0) requires a value") }
                )
            case "--dry-run":
                options.dryRun = true
                cursor.advance()
            default:
                throw InstallCommandError.message("unknown option: \(arg)")
            }
        }

        return options
    }

    package static func resolveBinDir(prefix: String?, bindir: String?) -> URL {
        if let bindir {
            return URL(fileURLWithPath: expandPath(bindir), isDirectory: true)
        }

        let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
        let expandedPrefix = expandPath(defaultPrefix)
        return URL(fileURLWithPath: expandedPrefix, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}
