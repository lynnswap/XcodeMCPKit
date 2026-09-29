import Foundation
import XcodeMCPProxyToolVerifier

@main
struct XcodeMCPProxyToolVerifierCLI {
    static func main() async {
        let status = await ProxyToolVerifierCommand.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        Foundation.exit(status)
    }
}
