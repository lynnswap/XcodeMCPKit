import ProxyCore
import ProxyMCP
import ProxyStdioTransport
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing
import XcodeMCPProxy
import ProxyCLI
import XcodeMCPTestSupport

@Suite(.serialized)
struct CLICommandIntegrationTests {
    @Test func cliCommandRoundTripsJSONOverModernStubHTTPServer() async throws {
        try await runCLICommandRoundTrip(responseMode: .json)
    }

    @Test func cliCommandAcceptsSingleSSEPostResponsesFromModernStubHTTPServer() async throws {
        try await runCLICommandRoundTrip(responseMode: .sse)
    }

    @Test func cliCommandEmitsEverySSEPostEventFromModernStubHTTPServer() async throws {
        let progressNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": ["value": 1],
        ]
        let server = try StubMCPHTTPServer.start(
            responseMode: .sse,
            postSSEPreludeEventsByMethod: ["tools/list": [progressNotification]]
        )
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            let toolsList = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            inputPipe.fileHandleForWriting.write(
                Data(initialize.utf8) + Data("\n".utf8) + Data(toolsList.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should emit all SSE POST events",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)

            let responseObjects = try parseOutputObjects(outputData)
            #expect(responseObjects.count == 3)
            #expect((responseObjects.first?["id"] as? NSNumber)?.intValue == 1)
            let notificationIndex = try #require(
                responseObjects.firstIndex {
                    ($0["method"] as? String) == "notifications/progress"
                }
            )
            let toolsListIndex = try #require(
                responseObjects.firstIndex {
                    ($0["id"] as? NSNumber)?.intValue == 2
                }
            )
            #expect(notificationIndex < toolsListIndex)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func cliCommandStartsSSEAfterInitializeResponseIsWritten() async throws {
        let startupNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/startup",
            "params": ["value": 1],
        ]
        let server = try StubMCPHTTPServer.start(
            responseMode: .json,
            delayedResponseMethod: "tools/list",
            delayedResponseMilliseconds: 1_000,
            getSSEEvents: [startupNotification]
        )
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            let toolsList = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            inputPipe.fileHandleForWriting.write(
                Data(initialize.utf8) + Data("\n".utf8) + Data(toolsList.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()
            let exitCode = try await waitWithTimeout(
                "CLI command should finish after stdin closes",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)

            let responseObjects = try parseOutputObjects(outputData)
            #expect((responseObjects.first?["id"] as? NSNumber)?.intValue == 1)
            #expect(server.recorder.snapshot().contains { $0.httpMethod == "GET" })
            if let notificationIndex = responseObjects.firstIndex(where: {
                ($0["method"] as? String) == "notifications/startup"
            }) {
                #expect(notificationIndex > 0)
            }
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func cliCommandDoesNotSerializeRequestsAfterInitialize() async throws {
        let server = try StubMCPHTTPServer.start(
            responseMode: .json,
            delayedResponseMethod: "tools/call"
        )
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            let slowCall = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow"}}"#
            let toolsList = #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#
            inputPipe.fileHandleForWriting.write(
                Data(initialize.utf8) + Data("\n".utf8)
                    + Data(slowCall.utf8) + Data("\n".utf8)
                    + Data(toolsList.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should finish after delayed concurrent request completes",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)

            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let responseIDs = try output
                .split(separator: "\n")
                .map { line in
                    let object = try #require(
                        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    )
                    return try #require((object["id"] as? NSNumber)?.intValue)
                }
            #expect(responseIDs.count == 3)
            #expect(responseIDs.first == 1)
            let slowResponseIndex = try #require(responseIDs.firstIndex(of: 2))
            let fastResponseIndex = try #require(responseIDs.firstIndex(of: 3))
            #expect(fastResponseIndex < slowResponseIndex)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func cliCommandBoundsDeleteOnShutdownWhenTimeoutIsDisabled() async throws {
        let server = try StubMCPHTTPServer.start(responseMode: .json, hangsDELETE: true)
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            inputPipe.fileHandleForWriting.write(Data(initialize.utf8) + Data("\n".utf8))
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should not hang waiting for best-effort DELETE",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                        "--request-timeout",
                        "0",
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)
            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let responseObject = try #require(
                JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            #expect((responseObject["id"] as? NSNumber)?.intValue == 1)
            #expect(server.recorder.snapshot().contains { $0.httpMethod == "DELETE" })
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func cliCommandTreatsAcceptedJSONRPCResponseAsAcknowledged() async throws {
        let server = try StubMCPHTTPServer.start(responseMode: .json)
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            let response = #"{"jsonrpc":"2.0","id":99,"result":{"ok":true}}"#
            inputPipe.fileHandleForWriting.write(
                Data(initialize.utf8) + Data("\n".utf8)
                    + Data(response.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should treat accepted JSON-RPC response as acknowledged",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)

            let responseObjects = try parseOutputObjects(outputData)
            #expect(responseObjects.count == 1)
            #expect((responseObjects.first?["id"] as? NSNumber)?.intValue == 1)

            let responsePost = try #require(
                server.recorder.snapshot().first {
                    $0.httpMethod == "POST" && $0.bodyMethod == nil
                }
            )
            #expect(responsePost.sessionID == "server-session")
            #expect(responsePost.protocolVersion == MCP.ProtocolVersion.current)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func cliCommandSendsDeleteAfterTimedOutDrainWithLongRunningRequest() async throws {
        let server = try StubMCPHTTPServer.start(
            responseMode: .json,
            hangingResponseMethod: "tools/call"
        )
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            let longRunningCall = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow"}}"#
            inputPipe.fileHandleForWriting.write(
                Data(initialize.utf8) + Data("\n".utf8)
                    + Data(longRunningCall.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should delete the session after timed-out drain",
                timeout: .seconds(6)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                        "--request-timeout",
                        "0",
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)
            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let responseIDs = try output
                .split(separator: "\n")
                .map { line in
                    let object = try #require(
                        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    )
                    return try #require((object["id"] as? NSNumber)?.intValue)
                }
            #expect(responseIDs.contains(1))

            let delete = try #require(server.recorder.snapshot().first { $0.httpMethod == "DELETE" })
            #expect(delete.sessionID == "server-session")
            #expect(delete.protocolVersion == MCP.ProtocolVersion.current)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func cliCommandDeletesUninitializedSessionAfterInitializeWithoutProtocol() async throws {
        let server = try StubMCPHTTPServer.start(
            responseMode: .json,
            initializeProtocolVersion: nil
        )
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            inputPipe.fileHandleForWriting.write(Data(initialize.utf8) + Data("\n".utf8))
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should delete uninitialized session after EOF",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)
            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let responseObject = try #require(
                JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            #expect((responseObject["id"] as? NSNumber)?.intValue == 1)

            let delete = try #require(server.recorder.snapshot().first { $0.httpMethod == "DELETE" })
            #expect(delete.sessionID == "server-session")
            #expect(delete.protocolVersion == nil)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    private func runCLICommandRoundTrip(responseMode: StubMCPHTTPResponseMode) async throws {
        let server = try StubMCPHTTPServer.start(responseMode: responseMode)
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
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
                input: inputPipe.fileHandleForReading,
                output: outputPipe.fileHandleForWriting
            )
        )

        do {
            let initialize =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
            let toolsList = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            inputPipe.fileHandleForWriting.write(
                Data(initialize.utf8) + Data("\n".utf8) + Data(toolsList.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()

            let exitCode = try await waitWithTimeout(
                "CLI command should finish after stdin closes",
                timeout: .seconds(5)
            ) {
                await command.run(
                    args: [
                        "xcode-mcp-proxy",
                        "--url",
                        server.url.absoluteString,
                    ],
                    environment: [:]
                )
            }
            outputPipe.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            #expect(exitCode == 0)
            #expect(errors.snapshot().isEmpty)

            let responseObjects = try parseOutputObjects(outputData)
            #expect(responseObjects.count == 2)
            #expect((responseObjects.first?["id"] as? NSNumber)?.intValue == 1)
            #expect((responseObjects.last?["id"] as? NSNumber)?.intValue == 2)
            let result = responseObjects.last?["result"] as? [String: Any]
            #expect(result?["transport"] as? String == "stub")

            let requests = server.recorder.snapshot()
            let initializePost = try #require(requests.first { $0.bodyMethod == "initialize" })
            #expect(initializePost.httpMethod == "POST")
            #expect(initializePost.sessionID == nil)
            #expect(initializePost.protocolVersion == nil)
            #expect(initializePost.accept == "application/json, text/event-stream")
            #expect(initializePost.contentType == "application/json")

            let toolsPost = try #require(requests.first { $0.bodyMethod == "tools/list" })
            #expect(toolsPost.httpMethod == "POST")
            #expect(toolsPost.sessionID == "server-session")
            #expect(toolsPost.protocolVersion == MCP.ProtocolVersion.current)
            #expect(toolsPost.accept == "application/json, text/event-stream")
            #expect(toolsPost.contentType == "application/json")

            let sseGet = try #require(requests.first { $0.httpMethod == "GET" })
            #expect(sseGet.sessionID == "server-session")
            #expect(sseGet.protocolVersion == MCP.ProtocolVersion.current)
            #expect(sseGet.accept == "text/event-stream")

            let delete = try #require(requests.first { $0.httpMethod == "DELETE" })
            #expect(delete.sessionID == "server-session")
            #expect(delete.protocolVersion == MCP.ProtocolVersion.current)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    private func parseOutputObjects(_ data: Data) throws -> [[String: Any]] {
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.isEmpty == false else { return [] }
        return try output
            .split(separator: "\n")
            .map { line in
                try #require(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
            }
    }
}

private struct StubMCPHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let childChannelTracker: HTTPTestServerChannelTracker
    let recorder: StubMCPHTTPRecorder

    static func start(
        responseMode: StubMCPHTTPResponseMode,
        delayedResponseMethod: String? = nil,
        delayedResponseMilliseconds: Int = 250,
        hangingResponseMethod: String? = nil,
        initializeProtocolVersion: String? = MCP.ProtocolVersion.current,
        hangsDELETE: Bool = false,
        postSSEPreludeEventsByMethod: [String: [[String: Any]]] = [:],
        getSSEEvents: [[String: Any]] = []
    ) throws -> StubMCPHTTPServer {
        let postSSEPreludeEventDataByMethod = postSSEPreludeEventsByMethod.mapValues { events in
            events.compactMap { stubSSEEventData(for: $0) }
        }
        let getSSEEventData = getSSEEvents.compactMap { stubSSEEventData(for: $0) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let recorder = StubMCPHTTPRecorder()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        StubMCPHTTPHandler(
                            recorder: recorder,
                            responseMode: responseMode,
                            delayedResponseMethod: delayedResponseMethod,
                            delayedResponseMilliseconds: delayedResponseMilliseconds,
                            hangingResponseMethod: hangingResponseMethod,
                            initializeProtocolVersion: initializeProtocolVersion,
                            hangsDELETE: hangsDELETE,
                            postSSEPreludeEventDataByMethod: postSSEPreludeEventDataByMethod,
                            getSSEEventData: getSSEEventData
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        try channel.pipeline.addHandler(
            HTTPTestServerAcceptedChannelHandler(tracker: childChannelTracker)
        ).wait()
        let port = try #require(channel.localAddress?.port)
        return StubMCPHTTPServer(
            group: group,
            channel: channel,
            url: URL(string: "http://127.0.0.1:\(port)/mcp")!,
            childChannelTracker: childChannelTracker,
            recorder: recorder
        )
    }

    func shutdown() async throws {
        try await shutdownHTTPTestServer(
            listenChannel: channel,
            childChannelTracker: childChannelTracker,
            group: group
        )
    }
}

private enum StubMCPHTTPResponseMode: Sendable {
    case json
    case sse
}

private struct StubMCPHTTPRequest: Sendable {
    let httpMethod: String
    let bodyMethod: String?
    let sessionID: String?
    let protocolVersion: String?
    let accept: String?
    let contentType: String?
}

private final class StubMCPHTTPRecorder: @unchecked Sendable {
    private let requests = NIOLockedValueBox<[StubMCPHTTPRequest]>([])

    func append(_ request: StubMCPHTTPRequest) {
        requests.withLockedValue { requests in
            requests.append(request)
        }
    }

    func snapshot() -> [StubMCPHTTPRequest] {
        requests.withLockedValue { $0 }
    }
}

private final class StubMCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorder: StubMCPHTTPRecorder
    private let responseMode: StubMCPHTTPResponseMode
    private let delayedResponseMethod: String?
    private let delayedResponseMilliseconds: Int
    private let hangingResponseMethod: String?
    private let initializeProtocolVersion: String?
    private let hangsDELETE: Bool
    private let postSSEPreludeEventDataByMethod: [String: [Data]]
    private let getSSEEventData: [Data]
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = ByteBufferAllocator().buffer(capacity: 0)

    init(
        recorder: StubMCPHTTPRecorder,
        responseMode: StubMCPHTTPResponseMode,
        delayedResponseMethod: String?,
        delayedResponseMilliseconds: Int,
        hangingResponseMethod: String?,
        initializeProtocolVersion: String?,
        hangsDELETE: Bool,
        postSSEPreludeEventDataByMethod: [String: [Data]],
        getSSEEventData: [Data]
    ) {
        self.recorder = recorder
        self.responseMode = responseMode
        self.delayedResponseMethod = delayedResponseMethod
        self.delayedResponseMilliseconds = delayedResponseMilliseconds
        self.hangingResponseMethod = hangingResponseMethod
        self.initializeProtocolVersion = initializeProtocolVersion
        self.hangsDELETE = hangsDELETE
        self.postSSEPreludeEventDataByMethod = postSSEPreludeEventDataByMethod
        self.getSSEEventData = getSSEEventData
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
        case .body(var buffer):
            bodyBuffer.writeBuffer(&buffer)
        case .end:
            handleRequest(context: context)
            requestHead = nil
            bodyBuffer.clear()
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let requestHead else { return }
        let requestData = Data(bodyBuffer.readableBytesView)
        let requestObject =
            (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any]
        recorder.append(
            StubMCPHTTPRequest(
                httpMethod: requestHead.method.rawValue,
                bodyMethod: requestObject?["method"] as? String,
                sessionID: requestHead.headers.first(name: "MCP-Session-Id"),
                protocolVersion: requestHead.headers.first(name: "MCP-Protocol-Version"),
                accept: requestHead.headers.first(name: "Accept"),
                contentType: requestHead.headers.first(name: "Content-Type")
            )
        )

        switch requestHead.method {
        case .GET:
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/event-stream")
            headers.add(name: "Cache-Control", value: "no-cache")
            headers.add(name: "Connection", value: "keep-alive")
            let responseHead = HTTPResponseHead(
                version: requestHead.version,
                status: .ok,
                headers: headers
            )
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            var preamble = context.channel.allocator.buffer(capacity: 6)
            preamble.writeString(": ok\n\n")
            context.write(wrapOutboundOut(.body(.byteBuffer(preamble))), promise: nil)
            for eventData in getSSEEventData {
                var buffer = context.channel.allocator.buffer(capacity: eventData.count)
                buffer.writeBytes(eventData)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.flush()
        case .POST:
            if let requestObject,
                stubIsJSONRPCResponse(requestObject)
            {
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                let responseHead = HTTPResponseHead(
                    version: requestHead.version,
                    status: .accepted,
                    headers: headers
                )
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
            if requestObject?["method"] as? String == hangingResponseMethod {
                return
            }
            let isInitialize = requestObject?["method"] as? String == "initialize"
            let resultObject: [String: Any]
            if isInitialize {
                var initializeResult: [String: Any] = [
                    "capabilities": [String: Any](),
                ]
                if let initializeProtocolVersion {
                    initializeResult["protocolVersion"] = initializeProtocolVersion
                }
                resultObject = initializeResult
            } else {
                resultObject = [
                    "transport": "stub",
                ]
            }
            let responseObject: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestObject?["id"] as Any,
                "result": resultObject,
            ]
            let responseData =
                (try? JSONSerialization.data(withJSONObject: responseObject, options: []))
                ?? Data("{}".utf8)

            var headers = HTTPHeaders()
            if isInitialize {
                headers.add(name: "MCP-Session-Id", value: "server-session")
            }
            let responseBody: Data
            switch responseMode {
            case .json:
                responseBody = responseData
                headers.add(name: "Content-Type", value: "application/json")
            case .sse:
                let method = requestObject?["method"] as? String
                var events = method.flatMap { postSSEPreludeEventDataByMethod[$0] } ?? []
                if let responseEvent = stubSSEEventData(for: responseObject) {
                    events.append(responseEvent)
                }
                responseBody = Self.sseResponseData(events: events)
                headers.add(name: "Content-Type", value: "text/event-stream")
            }
            headers.add(name: "Content-Length", value: "\(responseBody.count)")
            let responseHead = HTTPResponseHead(
                version: requestHead.version,
                status: .ok,
                headers: headers
            )
            if requestObject?["method"] as? String == delayedResponseMethod {
                let sendableContext = SendableChannelHandlerContext(value: context)
                context.eventLoop.scheduleTask(in: .milliseconds(Int64(delayedResponseMilliseconds))) {
                    self.sendPOSTResponse(
                        context: sendableContext.value,
                        responseHead: responseHead,
                        responseBody: responseBody
                    )
                }
            } else {
                sendPOSTResponse(
                    context: context,
                    responseHead: responseHead,
                    responseBody: responseBody
                )
            }
        case .DELETE:
            if hangsDELETE {
                return
            }
            let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        default:
            let responseHead = HTTPResponseHead(version: requestHead.version, status: .methodNotAllowed)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private func sendPOSTResponse(
        context: ChannelHandlerContext,
        responseHead: HTTPResponseHead,
        responseBody: Data
    ) {
        var buffer = context.channel.allocator.buffer(capacity: responseBody.count)
        buffer.writeBytes(responseBody)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private static func sseResponseData(events: [Data]) -> Data {
        var data = Data()
        for eventData in events {
            data.append(eventData)
        }
        return data
    }
}

private struct SendableChannelHandlerContext: @unchecked Sendable {
    let value: ChannelHandlerContext
}

private func stubSSEEventData(for object: [String: Any]) -> Data? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
        return nil
    }
    return Data("event: message\ndata: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
}

private func stubIsJSONRPCResponse(_ object: [String: Any]) -> Bool {
    guard object["method"] == nil,
        let id = object["id"],
        JSONRPC.ID(any: id) != nil
    else {
        return false
    }
    return object["result"] != nil || object["error"] != nil
}

extension XcodeMCPProxyCLICommand: @unchecked Sendable {}
