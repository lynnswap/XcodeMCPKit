import Foundation
import XcodeMCPToolVerifier

@main
struct XcodeMCPToolVerifierCLI {
    static func main() async {
        let status = await ToolVerifierCommand.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        Foundation.exit(status)
    }
}
