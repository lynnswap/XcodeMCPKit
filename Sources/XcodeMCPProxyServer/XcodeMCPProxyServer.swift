import Foundation
import XcodeMCPProxyKit

@main
struct XcodeMCPProxyServerMain {
    static func main() async {
        XcodeMCPProxyKit.XcodeMCPProxyServer.bootstrapLogging(
            environment: ProcessInfo.processInfo.environment
        )
        let exitCode = await XcodeMCPProxyKit.XcodeMCPProxyServer.run(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            stdout: { print($0) },
            stderr: XcodeMCPProxyConsole.writeStandardErrorLine
        )
        guard exitCode != 0 else {
            return
        }
        exit(exitCode)
    }
}
