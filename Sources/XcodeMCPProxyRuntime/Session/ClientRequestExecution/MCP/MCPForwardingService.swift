import Foundation
import NIO
import XcodeMCPCore

struct MCPForwardingService: Sendable {
    typealias PreparedRequest = ProxyUpstreamRequestRuntime.PreparedRequest
    typealias StartedRequest = ProxyUpstreamRequestRuntime.StartedRequest

    enum ResponseResolution: Sendable {
        case success(Data)
        case timeout
        case upstreamUnavailable
        case invalidUpstreamResponse
        case failure(any Error)
    }

    private let sessionManager: any RuntimeMCPForwardingPort
    private let requestTimeoutSeconds: TimeInterval
    private let upstreamRuntime: ProxyUpstreamRequestRuntime
    private let toolSurface: ToolSurface

    init(configuration: ProxyRuntimeConfiguration, sessionManager: any RuntimeMCPForwardingPort) {
        self.requestTimeoutSeconds = configuration.requestTimeout
        self.sessionManager = sessionManager
        self.upstreamRuntime = ProxyUpstreamRequestRuntime(port: sessionManager)
        self.toolSurface = ToolSurface()
    }

    func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        operationLeaseOverride: UpstreamOperationLease? = nil,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil
    ) throws -> PreparedRequest? {
        guard let candidate = try upstreamRuntime.prepareRequest(
            bodyData: bodyData,
            parsedRequestJSON: parsedRequestJSON,
            sessionID: sessionID,
            operationLeaseOverride: operationLeaseOverride,
        ) else {
            return nil
        }
        let prepared = PreparedRequest(
            transform: candidate.transform,
            sessionID: candidate.sessionID,
            operationLease: candidate.operationLease,
            toolDefinition: candidate.transform.toolName.flatMap {
                sessionManager.toolDefinition(named: $0, sourceProof: candidate.operationLease.proof)
            }
        )
        guard let cancellationHandle else {
            return prepared
        }
        let requestIDKeys = prepared.transform.responseID.map { [$0.key] } ?? []
        guard cancellationHandle.bindPreparedRequest(
            operationLease: prepared.operationLease,
            requestIDKeys: requestIDKeys
        ) else {
            for requestIDKey in requestIDKeys {
                sessionManager.removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    operationLease: prepared.operationLease
                )
            }
            throw CancellationError()
        }
        return prepared
    }

    func startRequest(
        _ prepared: PreparedRequest,
        session: SessionContext,
        on eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        leaseID: LeaseManager.ID? = nil,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil,
        onTimeout: (@Sendable (UpstreamRequestSendCompletion) -> Void)? = nil
    ) throws -> StartedRequest {
        let requestTimeout =
            requestTimeoutOverride
            ?? MCP.MethodDispatcher.timeoutForMethod(
                prepared.transform.method,
                defaultSeconds: requestTimeoutSeconds
            )
        return try upstreamRuntime.startRequest(
            prepared,
            router: session.router,
            on: eventLoop,
            requestTimeout: requestTimeout,
            leaseID: leaseID,
            onRegistered: { registration in
                guard let cancellationHandle else { return }
                guard cancellationHandle.bindStartedRegistration(
                    operationLease: registration.operationLease,
                    routerPendingToken: registration.routerPendingToken,
                    requestSendCompletion: registration.requestSendCompletion
                ) else {
                    throw CancellationError()
                }
            },
            onTimeout: onTimeout
        )
    }

    func resolveResponse(
        _ result: Result<ByteBuffer, Error>,
        started: StartedRequest,
        sessionID: String,
        accountSuccess: Bool = true,
        accountTimeout: Bool = true
    ) -> ResponseResolution {
        switch result {
        case .success(let buffer):
            var buffer = buffer
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                return .invalidUpstreamResponse
            }
            let rewritten = toolSurface.rewriteForwardedResponse(
                method: started.transform.method,
                toolName: started.transform.toolName,
                originalID: started.transform.originalID,
                cachesToolsListResult: started.transform.isCacheableToolsListRequest,
                toolDefinition: started.toolDefinition,
                upstreamData: data
            )
            let responseData = rewritten.responseData
            if accountSuccess, toolSurface.shouldNotifyUpstreamSuccess(for: responseData) {
                upstreamRuntime.recordRequestSucceeded(
                    sessionID: sessionID,
                    started: started
                )
            }
            return .success(responseData)

        case .failure(let error):
            let error = ControlPlane.ErrorMapper.underlyingError(error)
            let isTimeout = error is TimeoutError
            upstreamRuntime.recordRequestFailed(
                sessionID: sessionID,
                started: started,
                accountTimeout: accountTimeout && isTimeout
            )
            if isTimeout {
                return .timeout
            }
            if error is UpstreamSlotScheduler.AcquisitionError {
                return .upstreamUnavailable
            }
            if case ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology = error {
                return .upstreamUnavailable
            }
            return .failure(error)
        }
    }
}
