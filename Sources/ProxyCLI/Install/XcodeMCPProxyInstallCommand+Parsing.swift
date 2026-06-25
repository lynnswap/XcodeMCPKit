import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

extension XcodeMCPProxyInstallCommand {
    package static func scanInvocation(_ args: [String]) -> XcodeMCPProxyInstallCommand.Invocation {
        let scan = ProxyCLIInvocationScanner.scanInstall(args)
        var invocation = XcodeMCPProxyInstallCommand.Invocation()
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

    package static func parseOptions(
        _ args: [String],
        environment: [String: String]
    ) throws -> XcodeMCPProxyInstallCommand.Options {
        var options = XcodeMCPProxyInstaller.Configuration(
            prefix: environment["PREFIX"],
            bindir: environment["BINDIR"],
            dryRun: false
        )

        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                index += 1
            case "--prefix":
                guard index + 1 < args.count else {
                    throw XcodeMCPProxyInstallCommand.Error.message("\(arg) requires a value")
                }
                options.prefix = args[index + 1]
                index += 2
            case "--bindir":
                guard index + 1 < args.count else {
                    throw XcodeMCPProxyInstallCommand.Error.message("\(arg) requires a value")
                }
                options.bindir = args[index + 1]
                index += 2
            case "--dry-run":
                options.dryRun = true
                index += 1
            default:
                throw XcodeMCPProxyInstallCommand.Error.message("unknown option: \(arg)")
            }
        }

        return options
    }
}
