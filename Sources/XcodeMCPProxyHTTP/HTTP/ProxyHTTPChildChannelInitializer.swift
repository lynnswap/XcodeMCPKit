import Logging
import NIO
import NIOHTTP1
import XcodeMCPProxyRuntimeContract

package final class ProxyHTTPChildChannelInitializer: @unchecked Sendable {
    private let config: ProxyHTTPConfiguration
    private let controlService: HTTPControlService
    private let logger: Logger

    package init(
        config: ProxyHTTPConfiguration,
        runtime: any ProxyRuntimeServing,
        logger: Logger
    ) {
        self.config = config
        self.controlService = HTTPControlService(runtime: runtime)
        self.logger = logger
    }

    package func initialize(_ channel: Channel) -> EventLoopFuture<Void> {
        controlService.startSessionExpirySweep(on: channel.eventLoop)
        return Self.configure(
            channel.pipeline,
            handler: HTTPHandler(config: config, controlService: controlService)
        ).flatMapError { error in
            self.logger.warning(
                "Child channel initialization failed.",
                metadata: [
                    "error": "\(error)"
                ]
            )
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    /// Adds the HTTP server pipeline that ends in `handler`.
    static func configure(_ pipeline: ChannelPipeline, handler: HTTPHandler) -> EventLoopFuture<Void> {
        // NIO's pipelining assistance stops reading while a response is pending, so a client that
        // leaves an event stream or a running request would never be noticed.
        pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true).flatMap {
            pipeline.addHandler(handler)
        }
    }

    func cancel() {
        controlService.cancel()
    }

    func shutdown() async {
        await controlService.shutdown()
    }
}
