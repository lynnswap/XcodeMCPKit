import Darwin
import Foundation
import XcodeMCPProxy

extension ProxyServer: ProxyServerCommandServer {}

package struct ProxyServerOptions {
    package var forwardedArgs: [String]
    package var showHelp: Bool
    package var showVersion: Bool
    package var hasListenFlag: Bool
    package var hasHostFlag: Bool
    package var hasPortFlag: Bool
    package var hasConfigFlag: Bool
    package var hasAutoApproveFlag: Bool
    package var hasRefreshCodeIssuesModeFlag: Bool
    package var forceRestart: Bool
    package var dryRun: Bool

    package init(
        forwardedArgs: [String],
        showHelp: Bool,
        showVersion: Bool,
        hasListenFlag: Bool,
        hasHostFlag: Bool,
        hasPortFlag: Bool,
        hasConfigFlag: Bool,
        hasAutoApproveFlag: Bool,
        hasRefreshCodeIssuesModeFlag: Bool,
        forceRestart: Bool,
        dryRun: Bool
    ) {
        self.forwardedArgs = forwardedArgs
        self.showHelp = showHelp
        self.showVersion = showVersion
        self.hasListenFlag = hasListenFlag
        self.hasHostFlag = hasHostFlag
        self.hasPortFlag = hasPortFlag
        self.hasConfigFlag = hasConfigFlag
        self.hasAutoApproveFlag = hasAutoApproveFlag
        self.hasRefreshCodeIssuesModeFlag = hasRefreshCodeIssuesModeFlag
        self.forceRestart = forceRestart
        self.dryRun = dryRun
    }
}

package enum ProxyServerCommandError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

package struct XcodeMCPProxyServerCommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var terminateExistingServer: (String, Int) -> Bool
        package var makeServer: (ProxyConfig) -> any ProxyServerCommandServer
        package var isAddressAlreadyInUse: (Error) -> Bool
        package var detectExistingProxyServerPIDs: (String, Int) -> [Int]

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            terminateExistingServer: @escaping (String, Int) -> Bool,
            makeServer: @escaping (ProxyConfig) -> any ProxyServerCommandServer,
            isAddressAlreadyInUse: @escaping (Error) -> Bool,
            detectExistingProxyServerPIDs: @escaping (String, Int) -> [Int]
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.stderr = stderr
            self.terminateExistingServer = terminateExistingServer
            self.makeServer = makeServer
            self.isAddressAlreadyInUse = isAddressAlreadyInUse
            self.detectExistingProxyServerPIDs = detectExistingProxyServerPIDs
        }

        package static var live: Self {
            Self(
                bootstrapLogging: ProxyLogging.bootstrap,
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                terminateExistingServer: XcodeMCPProxyServerCommand.terminateExistingProxyServerIfNeeded,
                makeServer: { ProxyServer(config: $0) },
                isAddressAlreadyInUse: XcodeMCPProxyServerCommand.isAddressAlreadyInUse,
                detectExistingProxyServerPIDs: XcodeMCPProxyServerCommand.detectExistingProxyServerPIDs
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)
        return await ProxyServerCommandRuntime(dependencies: dependencies).execute(
            args: args,
            environment: environment
        )
    }
}
