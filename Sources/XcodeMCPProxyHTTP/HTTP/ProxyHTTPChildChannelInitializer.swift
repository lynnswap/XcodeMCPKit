import Logging
import NIO
import NIOHTTP1
import XcodeMCPProxyRuntime

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
        let pipeline = channel.pipeline
        return pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            pipeline.addHandler(
                HTTPHandler(
                    config: self.config,
                    controlService: self.controlService
                )
            )
        }.flatMapError { error in
            self.logger.warning(
                "Child channel initialization failed.",
                metadata: [
                    "error": "\(error)"
                ]
            )
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    func cancel() {
        controlService.cancel()
    }

    func shutdown() async {
        await controlService.shutdown()
    }
}
