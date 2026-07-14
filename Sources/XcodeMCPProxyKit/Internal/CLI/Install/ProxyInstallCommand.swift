import ArgumentParser

package struct ProxyInstallCommand: ParsableCommand {
    package init() {}

    package static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "xcode-mcp-proxy-install",
            abstract: "Install the Xcode MCP proxy executables.",
            version: XcodeMCPProxyServer.productMetadata.version
        )
    }

    @Option(help: ArgumentHelp("Install to this directory. Overrides --prefix.", valueName: "path"))
    var bindir: String?

    @Option(help: ArgumentHelp("Install to <path>/bin. Defaults to ~/.local.", valueName: "path"))
    var prefix: String?

    @Flag(help: "Print the install plan without copying files.")
    var dryRun = false

    package mutating func validate() throws {
        if let bindir, bindir.isEmpty {
            throw ValidationError("--bindir must not be empty")
        }
        if let prefix, prefix.isEmpty {
            throw ValidationError("--prefix must not be empty")
        }
    }
}
