import Foundation
import XcodeMCPProxyKit

let exitCode = XcodeMCPProxyInstaller.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    stdout: { print($0) },
    stderr: XcodeMCPProxyConsole.writeStandardErrorLine
)
if exitCode != 0 {
    exit(exitCode)
}
