import Foundation
import XcodeMCPProxyKit

@main
struct XcodeMCPProxyServer {
    static func main() async {
        let command = XcodeMCPProxyServerCommand()
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
