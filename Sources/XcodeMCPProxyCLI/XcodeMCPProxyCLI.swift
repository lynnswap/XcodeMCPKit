import Foundation
import XcodeMCPProxyKit

@main
struct XcodeMCPProxyCLI {
    static func main() async {
        let command = XcodeMCPProxyCLICommand()
        let exitCode = await command.run(
            args: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard exitCode != 0 else {
            return
        }
        exit(exitCode)
    }
}
