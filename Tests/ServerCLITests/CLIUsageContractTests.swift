import Testing
@testable import XcodeMCPServerKit

@Suite
struct CLIUsageContractTests {
    @Test func serverHelpIsGeneratedFromTheTypedCommandSurface() {
        let help = XcodeMCPServer.serverUsage

        #expect(help.contains("USAGE: xcode-mcp-server"))
        for option in [
            "--listen <host:port>",
            "--host <host>",
            "--port <port>",
            "--max-body-bytes <max-body-bytes>",
            "--request-timeout <request-timeout>",
            "--share-compilation-cache",
            "--auto-approve",
            "--debug-endpoints",
            "--force-restart",
            "--dry-run",
            "--version",
            "-h, --help",
        ] {
            #expect(help.contains(option))
        }
        for option in ["--config", "--native-host-bundle", "--developer-dir", "--refresh-code-issues-mode"] {
            #expect(!help.contains(option))
        }
        #expect(help.contains("--upstream-processes") == false)
        #expect(help.contains("--lazy-init") == false)
        #expect(help.contains("--xcode-pid") == false)
    }

    @Test func installerHelpComesFromItsCommandDefinition() {
        let installerHelp = XcodeMCPInstaller.installUsage
        #expect(installerHelp.contains("USAGE: xcode-mcp-install"))
        #expect(installerHelp.contains("--bindir <path>"))
        #expect(installerHelp.contains("--prefix <path>"))
        #expect(installerHelp.contains("--dry-run"))
    }
}
