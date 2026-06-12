import ProxyCore
import ProxyStdioTransport
import Foundation
import NIO
import NIOHTTP1
import Testing
import XcodeMCPProxy
import ProxyCLI
import XcodeMCPTestSupport

@Suite(.serialized)
struct CLICommandIntegrationTests {
    @Test func cliCommandRoundTripsJSONOverStubHTTPServer() async throws {
        let server = try StubMCPHTTPServer.start()
        let errors = CapturedLines()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    CLICommandLogSink(
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
            let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + Data("\n".utf8)
            inputPipe.fileHandleForWriting.write(request)
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

            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let responseObject = try #require(
                JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            #expect((responseObject["id"] as? NSNumber)?.intValue == 1)
            let result = responseObject["result"] as? [String: Any]
            #expect(result?["transport"] as? String == "stub")
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }
}

private struct StubMCPHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start() throws -> StubMCPHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(StubMCPHTTPHandler())
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
            childChannelTracker: childChannelTracker
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

private final class StubMCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = ByteBufferAllocator().buffer(capacity: 0)

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
            context.flush()
        case .POST:
            let requestData = Data(
                bodyBuffer.readableBytesView
            )
            let requestObject =
                (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any]
            let responseObject: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestObject?["id"] as Any,
                "result": [
                    "transport": "stub"
                ],
            ]
            let responseData =
                (try? JSONSerialization.data(withJSONObject: responseObject, options: []))
                ?? Data("{}".utf8)

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "\(responseData.count)")
            let responseHead = HTTPResponseHead(
                version: requestHead.version,
                status: .ok,
                headers: headers
            )
            var buffer = context.channel.allocator.buffer(capacity: responseData.count)
            buffer.writeBytes(responseData)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        default:
            let responseHead = HTTPResponseHead(version: requestHead.version, status: .methodNotAllowed)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

extension XcodeMCPProxyCLICommand: @unchecked Sendable {}
