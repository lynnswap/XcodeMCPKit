import Foundation

/// Shared knowledge of xcrun's argument grammar: which flags take values,
/// and which argument names the tool being invoked.
package enum XcrunArguments {
    package static func firstToolSelection(
        from args: [String]
    ) -> (toolName: String, preToolArguments: [String])? {
        let flagsWithValues: Set<String> = [
            "-sdk", "--sdk",
            "-toolchain", "--toolchain",
        ]

        var index = 0
        while index < args.count {
            let argument = args[index]
            if flagsWithValues.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return (argument, Array(args.prefix(index)))
        }

        return nil
    }

    package static func isXcrunCommand(_ command: String) -> Bool {
        command == "xcrun" || URL(fileURLWithPath: command).lastPathComponent == "xcrun"
    }

    /// Whether the configured upstream is the stock `xcrun ... mcpbridge`
    /// invocation, which is what the Xcode-specific readiness gating and
    /// the documentation provider key their availability on.
    package static func isDefaultMCPBridgeInvocation(config: ProxyConfig) -> Bool {
        guard isXcrunCommand(config.upstreamCommand),
              let toolName = firstToolSelection(from: config.upstreamArgs)?.toolName
        else {
            return false
        }
        return URL(fileURLWithPath: toolName).lastPathComponent == "mcpbridge"
    }
}
