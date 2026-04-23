import Foundation
import Logging
import XcodeMCPProxy

extension StdioAdapter: CLICommandAdapter {}

package struct CLICommandLogSink {
    package var error: (String) -> Void
    package var info: (String, Logger.Metadata) -> Void

    package init(
        error: @escaping (String) -> Void,
        info: @escaping (String, Logger.Metadata) -> Void
    ) {
        self.error = error
        self.info = info
    }
}

package struct CLICommandInvocation {
    package var showHelp = false
    package var showVersion = false
    package var usesRemovedURLHelper = false
    package var removedFlagMessage: String?
    package var hasExplicitURL = false
    package var hasStdioFlag = false
    package var serverOnlyFlag: String?
}

package struct XcodeMCPProxyCLICommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var makeLogSink: () -> CLICommandLogSink
        package var makeAdapter: (URL, TimeInterval, FileHandle, FileHandle) -> any CLICommandAdapter
        package var input: FileHandle
        package var output: FileHandle

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            makeLogSink: @escaping () -> CLICommandLogSink,
            makeAdapter: @escaping (URL, TimeInterval, FileHandle, FileHandle) -> any CLICommandAdapter,
            input: FileHandle,
            output: FileHandle
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.makeLogSink = makeLogSink
            self.makeAdapter = makeAdapter
            self.input = input
            self.output = output
        }

        package static var live: Self {
            return Self(
                bootstrapLogging: ProxyLogging.bootstrap,
                stdout: { print($0) },
                makeLogSink: {
                    let logger = ProxyLogging.make("cli")
                    return CLICommandLogSink(
                        error: { logger.error("\($0)") },
                        info: { message, metadata in
                            logger.info("\(message)", metadata: metadata)
                        }
                    )
                },
                makeAdapter: { upstreamURL, requestTimeout, input, output in
                    StdioAdapter(
                        upstreamURL: upstreamURL,
                        requestTimeout: requestTimeout,
                        input: input,
                        output: output
                    )
                },
                input: .standardInput,
                output: .standardOutput
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)
        return await CLICommandRuntime(dependencies: dependencies).execute(
            args: args,
            environment: environment
        )
    }
}
