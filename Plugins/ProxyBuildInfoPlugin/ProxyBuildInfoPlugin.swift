import Foundation
import PackagePlugin

@main
struct ProxyBuildInfoPlugin: BuildToolPlugin {
    private static let environmentKey = "XCODE_MCP_BUILD_VERSION"

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target is SourceModuleTarget else {
            return []
        }

        let outputFile = context.pluginWorkDirectoryURL.appending(path: "BuildInfo.generated.swift")
        let tool = try context.tool(named: "ProxyBuildInfoTool")
        var arguments = [
            "--output", outputFile.path,
            "--package-directory", context.package.directoryURL.path,
        ]
        if let environmentVersion = ProcessInfo.processInfo.environment[Self.environmentKey] {
            arguments.append(contentsOf: ["--environment-version", environmentVersion])
        }

        return [
            .buildCommand(
                displayName: "Generate build info for \(target.name)",
                executable: tool.url,
                arguments: arguments,
                outputFiles: [outputFile]
            )
        ]
    }
}
