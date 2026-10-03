import Testing
@testable import XcodeMCPProxyKit

@Suite
struct CLIUsageContractTests {
    @Test func serverHelpIsGeneratedFromTheTypedCommandSurface() {
        let help = XcodeMCPProxyServer.serverUsage

        #expect(help.contains("USAGE: xcode-mcp-proxy-server"))
        for option in [
            "--listen <host:port>",
            "--host <host>",
            "--port <port>",
            "--config <path>",
            "--auto-approve",
            "--max-body-bytes <max-body-bytes>",
            "--request-timeout <request-timeout>",
            "--native-host-bundle <path>",
            "--developer-dir <path>",
            "--refresh-code-issues-mode <refresh-code-issues-mode>",
            "--force-restart",
            "--dry-run",
            "--version",
            "-h, --help",
        ] {
            #expect(help.contains(option))
        }
        #expect(help.contains("--upstream-processes") == false)
        #expect(help.contains("--lazy-init") == false)
        #expect(help.contains("--xcode-pid") == false)
    }

    @Test func adapterAndInstallerHelpComeFromTheirCommandDefinitions() {
        let adapterHelp = ProxyAdapterCommand.helpMessage()
        #expect(adapterHelp.contains("USAGE: xcode-mcp-proxy"))
        #expect(adapterHelp.contains("--url <url>"))
        #expect(adapterHelp.contains("--request-timeout <request-timeout>"))

        let installerHelp = XcodeMCPProxyInstaller.installUsage
        #expect(installerHelp.contains("USAGE: xcode-mcp-proxy-install"))
        #expect(installerHelp.contains("--bindir <path>"))
        #expect(installerHelp.contains("--prefix <path>"))
        #expect(installerHelp.contains("--dry-run"))
    }
}
