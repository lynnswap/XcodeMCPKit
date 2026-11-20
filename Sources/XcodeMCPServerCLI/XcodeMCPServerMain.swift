import Foundation
import XcodeMCPServerKit

@main
struct XcodeMCPServerMain {
    static func main() async {
        XcodeMCPServerKit.XcodeMCPServer.bootstrapLogging(
            environment: ProcessInfo.processInfo.environment
        )
        let exitCode = await XcodeMCPServerKit.XcodeMCPServer.run(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            stdout: { print($0) },
            stderr: XcodeMCPConsole.writeStandardErrorLine
        )
        guard exitCode != 0 else {
            return
        }
        exit(exitCode)
    }
}
