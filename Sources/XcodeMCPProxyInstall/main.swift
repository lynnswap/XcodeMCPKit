import Foundation
import ProxyInstallCLI

let command = XcodeMCPProxyInstallCommand()
let exitCode = command.run(
    args: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
)
if exitCode != 0 {
    exit(exitCode)
}
