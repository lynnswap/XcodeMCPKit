import Foundation
import Darwin
import OSLog
import ProxyCLI

@main
struct XcodeMCPProxyServer {
    private static let logger = Logger(subsystem: "com.xcodemcproxy", category: "XcodeMCPProxyServer")

    static func main() async {
        let parentWatcherTask = parentWatcherTaskIfConfigured()
        defer {
            parentWatcherTask?.cancel()
        }

        let command = XcodeMCPProxyServerCommand()
        let exitCode = await command.run(
            args: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard exitCode != 0 else {
            return
        }
        exit(exitCode)
    }

    private static func parentWatcherTaskIfConfigured() -> Task<Void, Never>? {
        guard
            let configuredParentPID = ProcessInfo.processInfo.environment["XCODE_MCP_PROXY_PARENT_PID"],
            let parentPID = Int32(configuredParentPID),
            parentPID > 1
        else {
            return nil
        }

        return Task.detached(priority: .background) {
            let currentPID = getpid()

            while Task.isCancelled == false {
                if getppid() != parentPID {
                    logger.notice(
                        "Parent process \(parentPID, privacy: .public) is no longer alive. Terminating helper pid \(currentPID, privacy: .public)."
                    )
                    _ = kill(currentPID, SIGTERM)
                    return
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
