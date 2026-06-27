import Foundation
import ProxyCore

package enum PermissionDialogExecutableResolver {
    package static func additionalExecutableCandidates(
        config: ProxyConfig,
        executableLookupClient: ExecutableLookupClient = .liveValue
    ) -> [String] {
        var candidates: [String] = []
        if let resolvedUpstreamCommand = executableLookupClient.resolveExecutablePath(config.upstreamCommand) {
            candidates.append(resolvedUpstreamCommand)
        }

        if let xcrunInvocation = xcrunInvocation(from: config, executableLookupClient: executableLookupClient) {
            candidates.append(xcrunInvocation.commandPath)
            if let toolResolution = resolvedXcrunTool(
                from: xcrunInvocation.arguments,
                xcrunCommandPath: xcrunInvocation.commandPath,
                executableLookupClient: executableLookupClient
            ) {
                candidates.append(toolResolution)
            }
        }

        return candidates
    }

    private static func xcrunInvocation(
        from config: ProxyConfig,
        executableLookupClient: ExecutableLookupClient
    ) -> (commandPath: String, arguments: [String])? {
        if let resolvedCommand = executableLookupClient.resolveExecutablePath(config.upstreamCommand),
           resolvedCommand.hasSuffix("/xcrun") {
            return (resolvedCommand, config.upstreamArgs)
        }

        guard let xcrunIndex = config.upstreamArgs.firstIndex(where: { argument in
            if argument == "xcrun" {
                return true
            }
            guard let resolved = executableLookupClient.resolveExecutablePath(argument) else {
                return false
            }
            return resolved.hasSuffix("/xcrun")
        }) else {
            return nil
        }

        let commandArgument = config.upstreamArgs[xcrunIndex]
        let resolvedCommand = executableLookupClient.resolveExecutablePath(commandArgument) ?? commandArgument
        let remainingArguments = Array(config.upstreamArgs.dropFirst(xcrunIndex + 1))
        return (resolvedCommand, remainingArguments)
    }

    private static func resolvedXcrunTool(
        from upstreamArgs: [String],
        xcrunCommandPath: String,
        executableLookupClient: ExecutableLookupClient
    ) -> String? {
        guard let selection = XcrunArguments.firstToolSelection(from: upstreamArgs) else {
            return nil
        }
        return executableLookupClient.resolveXcrunToolPath(
            xcrunCommandPath,
            selection.toolName,
            selection.preToolArguments
        )
    }
}
