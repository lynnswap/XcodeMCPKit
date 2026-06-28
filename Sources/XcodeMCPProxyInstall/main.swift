import Foundation
import XcodeMCPProxyKit

let exitCode = XcodeMCPProxyInstaller.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    stdout: { print($0) },
    stderr: { writeStandardErrorLine($0) }
)
if exitCode != 0 {
    exit(exitCode)
}

private func writeStandardErrorLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
