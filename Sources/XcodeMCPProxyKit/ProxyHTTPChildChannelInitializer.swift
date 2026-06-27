import Logging
import NIO
import NIOHTTP1
import ProxyCore
import ProxySession
import ProxyXcodeFeatures

final class ProxyHTTPChildChannelInitializer: @unchecked Sendable {
    private let config: ProxyConfig
    private let sessionManager: any RuntimeCoordinating
    private let refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator
    private let refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver
    private let refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState
    private let logger: Logger

    init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator,
        refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver,
        refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState,
        logger: Logger
    ) {
        self.config = config
        self.sessionManager = sessionManager
        self.refreshCodeIssuesCoordinator = refreshCodeIssuesCoordinator
        self.refreshCodeIssuesTargetResolver = refreshCodeIssuesTargetResolver
        self.refreshCodeIssuesDebugState = refreshCodeIssuesDebugState
        self.logger = logger
    }

    func initialize(_ channel: Channel) -> EventLoopFuture<Void> {
        let pipeline = channel.pipeline
        return pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            pipeline.addHandler(
                HTTPHandler(
                    config: self.config,
                    sessionManager: self.sessionManager,
                    refreshCodeIssuesCoordinator: self.refreshCodeIssuesCoordinator,
                    refreshCodeIssuesTargetResolver: self.refreshCodeIssuesTargetResolver,
                    refreshCodeIssuesDebugState: self.refreshCodeIssuesDebugState
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
}
