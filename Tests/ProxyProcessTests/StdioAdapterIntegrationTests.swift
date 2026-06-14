import ProxyStdioTransport
import Foundation
import NIO
import NIOHTTP1
import Testing
import XcodeMCPProxy
import XcodeMCPTestSupport

@Suite(.serialized, .enabled(if: ProcessTestEnvironment.isEnabled))
struct StdioAdapterIntegrationTests {
    @Test func stdioAdapterDoesNotHangOnEOFWithStalledRequest() async throws {
        let server = try HangingHTTPServer.start()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let adapter = StdioAdapter(
            upstreamURL: server.url,
            requestTimeout: 0,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )

        do {
            let waitTask = Task {
                await adapter.start()
                await adapter.wait()
            }

            inputPipe.fileHandleForWriting.write(
                Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + Data("\n".utf8)
            )
            inputPipe.fileHandleForWriting.closeFile()

            let completed = try await waitWithTimeout(
                "StdioAdapter should cancel stalled requests after stdin closes",
                timeout: .seconds(2)
            ) {
                await waitTask.value
                return true
            }

            #expect(completed)
        } catch {
            try? await server.shutdown()
            throw error
        }

        outputPipe.fileHandleForWriting.closeFile()
        try await server.shutdown()
    }

    @Test func stdioAdapterStopsReadLoopAfterFatalInputProtocolViolation() async throws {
        let server = try HangingHTTPServer.start()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let adapter = StdioAdapter(
            upstreamURL: server.url,
            requestTimeout: 0,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )

        do {
            let waitTask = Task {
                await adapter.start()
                await adapter.wait()
            }

            inputPipe.fileHandleForWriting.write(Data("Content-Length: abc\r\n\r\n{}".utf8))

            let completed = try await waitWithTimeout(
                "StdioAdapter should stop after a fatal input protocol violation",
                timeout: .seconds(2)
            ) {
                await waitTask.value
                return true
            }

            #expect(completed)
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForWriting.closeFile()
            try? await server.shutdown()
            throw error
        }

        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        try await server.shutdown()
    }
}

private struct HangingHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start() throws -> HangingHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HangingHTTPHandler())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        try channel.pipeline.addHandler(
            HTTPTestServerAcceptedChannelHandler(tracker: childChannelTracker)
        ).wait()
        let port = try #require(channel.localAddress?.port)
        return HangingHTTPServer(
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

private final class HangingHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            handleRequest(context: context)
            requestHead = nil
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let requestHead else { return }

        if requestHead.method == .GET {
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
            return
        }

        // Intentionally never answer POST requests to simulate a stalled upstream.
    }
}
