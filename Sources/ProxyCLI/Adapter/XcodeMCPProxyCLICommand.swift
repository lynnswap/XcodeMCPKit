import Foundation
import ProxyCLICommon
import XcodeMCPProxyKit

extension XcodeMCPProxyStdioAdapter: CLICommandAdapter {}

package struct XcodeMCPProxyCLICommand {
    package typealias LogSink = XcodeMCPProxyStdioAdapter.LogSink

    package static func usage(discoveryFileURL: URL = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL()) -> String {
        XcodeMCPProxyStdioAdapter.adapterUsage(discoveryFileURL: discoveryFileURL)
    }

    package struct Dependencies {
        package typealias Launch = (
            _ args: [String],
            _ environment: [String: String],
            _ stdout: @escaping (String) -> Void
        ) async -> Int32

        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var launch: Launch

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            launcher: XcodeMCPProxyStdioAdapter.Launcher
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.launch = { args, environment, stdout in
                await launcher.run(
                    arguments: args,
                    environment: environment,
                    stdout: stdout
                )
            }
        }

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            launch: @escaping Launch
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.launch = launch
        }

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            makeLogSink: @escaping () -> XcodeMCPProxyCLICommand.LogSink,
            makeAdapter: @escaping (
                XcodeMCPProxyAdapterEndpoint,
                TimeInterval,
                FileHandle,
                FileHandle
            ) -> any CLICommandAdapter,
            input: FileHandle,
            output: FileHandle
        ) {
            let launcher = XcodeMCPProxyStdioAdapter.Launcher(
                dependencies: .init(
                    makeLogSink: makeLogSink,
                    makeAdapter: { endpoint, timeout, input, output in
                        CLICommandAdapterBox(
                            makeAdapter(endpoint, timeout, input, output)
                        )
                    },
                    input: input,
                    output: output
                )
            )
            self.init(
                bootstrapLogging: bootstrapLogging,
                stdout: stdout,
                launcher: launcher
            )
        }

        package static var live: Self {
            let launcher = XcodeMCPProxyStdioAdapter.Launcher()
            return Self(
                bootstrapLogging: XcodeMCPProxyLogging.bootstrap,
                stdout: { print($0) },
                launcher: launcher
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)
        return await dependencies.launch(args, environment, dependencies.stdout)
    }
}

private struct CLICommandAdapterBox: XcodeMCPProxyStdioAdapter.LaunchAdapter {
    private let adapter: any CLICommandAdapter

    init(_ adapter: any CLICommandAdapter) {
        self.adapter = adapter
    }

    func start() async {
        await adapter.start()
    }

    func wait() async {
        await adapter.wait()
    }
}
