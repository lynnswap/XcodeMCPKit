import Foundation
import XcodeMCPServerKit

let exitCode = XcodeMCPInstaller.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    stdout: { print($0) },
    stderr: XcodeMCPConsole.writeStandardErrorLine
)
if exitCode != 0 {
    exit(exitCode)
}
