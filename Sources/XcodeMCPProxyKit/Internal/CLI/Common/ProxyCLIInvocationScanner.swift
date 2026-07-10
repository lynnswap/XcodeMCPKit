import Foundation

package enum ProxyCLIInvocationScanner {
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

    package enum Error: Swift.Error, CustomStringConvertible {
        case message(String)

        package var description: String {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    package static let removedLazyInitMessage =
        "The proxy always uses eager initialization; --lazy-init has been removed."
    package static let removedXcodePIDMessage =
        "Xcode PID support has been removed; --xcode-pid is no longer supported."

    private static let serverForwardedValueFlags: Set<String> = [
        "--config",
        "--listen",
        "--host",
        "--port",
        "--max-body-bytes",
        "--upstream-command",
        "--upstream-args",
        "--upstream-arg",
        "--upstream-processes",
        "--session-id",
        "--request-timeout",
        "--refresh-code-issues-mode",
    ]

    package static func scanServer(_ args: [String]) throws -> ServerScan {
        var scan = ServerScan()
        scan.showVersion = containsVersionFlag(args)
        var cursor = ProxyCLIArgumentCursor(args: args)

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
                throw Error.message(
                    "--stdio is not supported in server mode (use xcode-mcp-proxy)"
                )
            case "--url":
                throw Error.message(
                    "--url is not supported in server mode (use xcode-mcp-proxy)"
                )
            case "--xcode-pid":
                throw Error.message(removedXcodePIDMessage)
            case "--lazy-init":
                throw Error.message(removedLazyInitMessage)
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
                    error: { Error.message("\($0) requires a value") }
                )
                scan.forwardedArgs.append(value)
            } else {
                cursor.advance()
            }
        }

        return scan
    }

    package static func scanInstall(_ args: [String]) -> InstallScan {
        var scan = InstallScan()
        scan.showVersion = containsVersionFlag(args)
        var cursor = ProxyCLIArgumentCursor(args: args)

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

    private static func containsVersionFlag(_ args: [String]) -> Bool {
        args.dropFirst().contains("--version")
    }
}
