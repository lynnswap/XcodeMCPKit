import Foundation
import XcodeMCPProxyKit

@main
struct XcodeMCPProxyCLI {
    static func main() async {
        XcodeMCPProxyLogging.bootstrap(environment: ProcessInfo.processInfo.environment)
        let exitCode = await XcodeMCPProxyStdioAdapter.run(
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
