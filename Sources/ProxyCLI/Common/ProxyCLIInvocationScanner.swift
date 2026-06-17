import Foundation
import ProxyCore
import XcodeMCPProxy

extension CLI {
    package enum InvocationScanner {
        package struct AdapterScan {
            package var showHelp = false
            package var showVersion = false
            package var usesRemovedURLHelper = false
            package var removedFlagMessage: String?
            package var hasExplicitURL = false
            package var hasStdioFlag = false
            package var serverOnlyFlag: String?
        }

        package struct ServerScan {
            package var forwardedArgs: [String] = []
            package var showHelp = false
            package var showVersion = false
            package var hasListenFlag = false
            package var hasHostFlag = false
            package var hasPortFlag = false
            package var hasConfigFlag = false
            package var hasAutoApproveFlag = false
            package var hasRefreshCodeIssuesModeFlag = false
            package var forceRestart = false
            package var dryRun = false
        }

        package struct InstallScan {
            package var showHelp = false
            package var showVersion = false
        }

        private static let serverOnlyFlags = CLI.Flag.serverOnlyFlagNames
        private static let serverOnlyValueFlags = CLI.Flag.serverOnlyValueFlagNames
        private static let serverForwardedValueFlags = CLI.Flag.serverForwardedValueFlagNames

        package static func scanAdapter(_ args: [String]) -> CLI.InvocationScanner.AdapterScan {
            var scan = CLI.InvocationScanner.AdapterScan()
            scan.showVersion = containsVersionFlag(args)
            var cursor = CLI.ArgumentCursor(args: args)

            while let arg = cursor.current {
                switch arg {
                case "-h", "--help":
                    scan.showHelp = true
                    cursor.advance()
                case "--version":
                    scan.showVersion = true
                    cursor.advance()
                case "url" where cursor.index == 1:
                    scan.usesRemovedURLHelper = true
                    cursor.advance()
                case "--print-url":
                    scan.usesRemovedURLHelper = true
                    cursor.advance()
                case "--url":
                    scan.hasExplicitURL = true
                    cursor.advancePastCurrentAndOptionalValue(where: { !$0.hasPrefix("-") })
                case let value where value.hasPrefix("--url="):
                    scan.hasExplicitURL = true
                    cursor.advance()
                case "--stdio":
                    scan.hasStdioFlag = true
                    cursor.advancePastCurrentAndOptionalValue(where: { !$0.hasPrefix("-") })
                case "--lazy-init":
                    if scan.removedFlagMessage == nil {
                        scan.removedFlagMessage = CLIParser.removedLazyInitMessage
                    }
                    cursor.advance()
                case "--xcode-pid":
                    if scan.removedFlagMessage == nil {
                        scan.removedFlagMessage = CLIParser.removedXcodePIDMessage
                    }
                    cursor.advancePastCurrentAndOptionalValue(where: { _ in true })
                case "--request-timeout":
                    cursor.advancePastCurrentAndOptionalValue(
                        where: shouldConsumeRequestTimeoutValue)
                case let flag where serverOnlyFlags.contains(flag):
                    if scan.serverOnlyFlag == nil {
                        scan.serverOnlyFlag = flag
                    }
                    if serverOnlyValueFlags.contains(flag) {
                        cursor.advancePastCurrentAndOptionalValue(where: { _ in true })
                    } else {
                        cursor.advance()
                    }
                default:
                    cursor.advance()
                }
            }

            return scan
        }

        package static func scanServer(_ args: [String]) throws -> CLI.InvocationScanner.ServerScan
        {
            var scan = CLI.InvocationScanner.ServerScan()
            scan.showVersion = containsVersionFlag(args)
            var cursor = CLI.ArgumentCursor(args: args)

            while let arg = cursor.current {
                if scan.showVersion {
                    switch arg {
                    case "-h", "--help":
                        scan.showHelp = true
                        return scan
                    default:
                        if serverForwardedValueFlags.contains(arg) {
                            if arg == "--refresh-code-issues-mode" {
                                cursor.advance()
                            } else {
                                cursor.advancePastCurrentAndOptionalValue(where: { _ in true })
                            }
                        } else {
                            cursor.advance()
                        }
                        continue
                    }
                }

                switch arg {
                case "-h", "--help":
                    scan.showHelp = true
                    return scan
                case "--version":
                    scan.showVersion = true
                    cursor.advance()
                    continue
                case "--dry-run":
                    scan.dryRun = true
                    cursor.advance()
                    continue
                case "--force-restart":
                    scan.forceRestart = true
                    cursor.advance()
                    continue
                case "--stdio":
                    throw XcodeMCPProxyServerCommand.Error.message(
                        "--stdio is not supported in server mode (use xcode-mcp-proxy)"
                    )
                case "--url":
                    throw XcodeMCPProxyServerCommand.Error.message(
                        "--url is not supported in server mode (use xcode-mcp-proxy)"
                    )
                case "--xcode-pid":
                    throw XcodeMCPProxyServerCommand.Error.message(CLIParser.removedXcodePIDMessage)
                case "--lazy-init":
                    throw XcodeMCPProxyServerCommand.Error.message(CLIParser.removedLazyInitMessage)
                case "--listen":
                    scan.hasListenFlag = true
                case "--host":
                    scan.hasHostFlag = true
                case "--port":
                    scan.hasPortFlag = true
                case "--config":
                    scan.hasConfigFlag = true
                case "--auto-approve":
                    scan.hasAutoApproveFlag = true
                case "--refresh-code-issues-mode":
                    scan.hasRefreshCodeIssuesModeFlag = true
                default:
                    break
                }

                scan.forwardedArgs.append(arg)
                if serverForwardedValueFlags.contains(arg) {
                    let value = try cursor.requiredValue(
                        for: arg,
                        error: {
                            XcodeMCPProxyServerCommand.Error.message("\($0) requires a value")
                        }
                    )
                    scan.forwardedArgs.append(value)
                } else {
                    cursor.advance()
                }
            }

            return scan
        }

        package static func scanInstall(_ args: [String]) -> CLI.InvocationScanner.InstallScan {
            var scan = CLI.InvocationScanner.InstallScan()
            scan.showVersion = containsVersionFlag(args)
            var cursor = CLI.ArgumentCursor(args: args)

            while let arg = cursor.current {
                switch arg {
                case "-h", "--help":
                    scan.showHelp = true
                    cursor.advance()
                case "--version":
                    scan.showVersion = true
                    cursor.advance()
                case "--prefix", "--bindir":
                    cursor.advancePastCurrentAndOptionalValue(where: { _ in true })
                case "--dry-run":
                    cursor.advance()
                default:
                    cursor.advance()
                }
            }

            return scan
        }

        package static func shouldConsumeRequestTimeoutValue(_ token: String) -> Bool {
            if token == "-h" || token == "--help" {
                return true
            }
            if Double(token) != nil {
                return true
            }
            return !token.hasPrefix("-")
        }

        private static func containsVersionFlag(_ args: [String]) -> Bool {
            args.dropFirst().contains("--version")
        }
    }
}
