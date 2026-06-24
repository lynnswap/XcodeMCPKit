import ProxyXcodeSupport
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import ProxyCore
import ProxyMCP
import ProxySessionControlPlane
import ProxySessionUpstream
import XcodeMCPTestSupport
@testable import ProxySession

@Suite(.serialized)
struct RuntimeCoordinatorTests {
    @Test func defaultUpstreamsDoNotInjectXcodePIDEnvironment() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_PID"] == nil)
    }

    @Test func defaultUpstreamsPassThroughInheritedMCPXcodePIDEnvironment() async throws {
        let environment = try withEnvironmentVariables(
            [
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
            ]
        ) {
            try defaultUpstreamEnvironment(sharedSessionID: nil)
        }

        #expect(environment["XCODE_PID"] == nil)
        #expect(environment["MCP_XCODE_PID"] == "5678")
    }

    @Test func defaultUpstreamsDoNotInjectSessionIDWhenConfigDoesNotSpecifyOne() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_SESSION_ID"] == nil)
    }

    @Test func defaultUpstreamsInjectExplicitSessionIDWhenConfigured() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: "session-explicit")

        #expect(environment["MCP_XCODE_SESSION_ID"] == "session-explicit")
    }

    @Test func upstreamStderrClassifierTreatsNoXcodeFatalAsAvailabilityWait() {
        let message =
            "mcpbridge/MCPBridge.swift:125: Fatal error: MCP_XCODE_PID environment variable not set and no running Xcode processes found"

        #expect(UpstreamStderrClassifier.classify(message) == .xcodeUnavailable)
    }

    @Test func upstreamStderrLogLimiterSuppressesRepeatedMessages() {
        let limiter = UpstreamStderrLogLimiter(duplicateLogIntervalNanoseconds: 1_000_000_000)
        let message = "some upstream stderr"
        let first = limiter.decision(
            upstreamIndex: 0,
            message: message,
            classification: .unknown,
            nowUptimeNs: 0
        )
        let second = limiter.decision(
            upstreamIndex: 0,
            message: message,
            classification: .unknown,
            nowUptimeNs: 100_000_000
        )
        let third = limiter.decision(
            upstreamIndex: 0,
            message: message,
            classification: .unknown,
            nowUptimeNs: 1_100_000_000
        )

        #expect(first.shouldLog)
        #expect(!second.shouldLog)
        #expect(third.shouldLog)
        #expect(third.suppressedDuplicateCount == 1)
    }

    @Test func upstreamStderrStillRecordsInDebugSnapshotWhenRateLimited() async throws {
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0)
        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0)

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams[0].recentStderr.count == 2)
    }

    @Test func sessionManagerQueuesInitializeRequests() async throws {
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { fixture.shutdownAndWait() }

        let future1 = fixture.registerInitialize(requestID: 1)
        let future2 = fixture.registerInitialize(requestID: 2)

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }

        let upstreamID = try extractUpstreamID(from: sent[0])
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        let response1 = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for first queued initialize response",
                timeout: .seconds(2)
            ) {
                try await future1.get()
            }
        )
        let response2 = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for second queued initialize response",
                timeout: .seconds(2)
            ) {
                try await future2.get()
            }
        )
        let id1 = (response1["id"] as? NSNumber)?.intValue
        let id2 = (response2["id"] as? NSNumber)?.intValue
        #expect(id1 == 1)
        #expect(id2 == 2)
    }

    @Test func sessionManagerJoinsEagerProcessInitializeInFlight() async throws {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 27001, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ]
        )
        defer { fixture.shutdownAndWait() }

        let eagerInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let eagerUpstreamID = try extractUpstreamID(from: eagerInitialize)
        let future = fixture.registerInitialize(requestID: 1)
        #expect(await upstream.sentCount() == 1)

        await upstream.yield(.message(try makeInitializeResponse(id: eagerUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeOnNextXcodeProcessAfterError()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let newerTarget = xcodeProcessTarget(processID: 27100, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26600, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { upstreamIndex in
                    initializedUpstreams.append(upstreamIndex)
                }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        let failedInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let failedUpstreamID = try extractUpstreamID(from: failedInitialize)
        await upstream0.yield(.message(try makeInitializeErrorResponse(id: failedUpstreamID)))

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstreams[0].isInitialized == false)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == true)

        let recoveryInitialize = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        let recoveryUpstreamID = try extractUpstreamID(from: recoveryInitialize)
        await upstream0.yield(.message(try makeInitializeResponse(id: recoveryUpstreamID)))
        _ = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let expectedCandidateProcessOrder = [
            newerTarget.processID,
            olderTarget.processID,
        ]
        let recoveredUpstreamIndex = try await waitWithTimeout(
            "waiting for recovered primary upstream initialization"
        ) {
            try await initializedUpstreams.nextValue(at: 1)
        }
        #expect(recoveredUpstreamIndex == 0)
        #expect(manager.testStateSnapshot().upstreams[0].isInitialized == true)
        #expect(manager.canonicalBrokerState.initializeSourceUpstream() == 1)
        #expect(manager.documentationCandidateProcessOrder() == expectedCandidateProcessOrder)
    }

    @Test func sessionManagerRoutesInitializeHandshakeNotificationsFromRetriedPrimaryProcess()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let newerTarget = xcodeProcessTarget(processID: 27104, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26604, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-retried-primary-handshake"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        let failedInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let failedUpstreamID = try extractUpstreamID(from: failedInitialize)
        await upstream0.yield(.message(try makeInitializeErrorResponse(id: failedUpstreamID)))

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 27104],
            ],
            options: []
        )
        let notificationEventIndex = upstreamEvents.count()
        await upstream1.yield(.message(notification))

        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for retried-primary initialize notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received == [notification])

        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))
        _ = try await future.get()
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeOnSiblingBeforeDroppingProcessAfterError()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 27103, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        let failedInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let failedUpstreamID = try extractUpstreamID(from: failedInitialize)
        await upstream0.yield(.message(try makeInitializeErrorResponse(id: failedUpstreamID)))

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstreams[0].isInitialized == false)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == true)
        #expect(manager.documentationCandidateProcessOrder() == [target.processID])
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeOnNextXcodeProcessAfterExit()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let newerTarget = xcodeProcessTarget(processID: 27101, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26601, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        _ = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let exitEventIndex = upstreamEvents.count()
        await upstream0.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for primary process-bound upstream exit"
        )

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == true)
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeWhenSendIsUnavailable()
        async throws
    {
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let retryUpstream = TestUpstreamClient()
        let newerTarget = xcodeProcessTarget(processID: 27102, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26602, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [unavailableUpstream, retryUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: retryUpstream, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await retryUpstream.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstreams[0].isInitialized == false)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == true)
    }

    @Test func sessionManagerMarksPrimaryUsableBeforeInitializeReturns() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        _ = try await fixture.initializePrimary(on: upstream)
        #expect(manager.chooseUpstreamIndex() == 0)
    }

    @Test func sessionManagerRejectsUnsupportedInitializeProtocolBeforeIssuingSession()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-unsupported-protocol"
        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": upstreamID,
            "result": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [])
        await upstream.yield(.message(responseData))

        let responseObject = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for unsupported initialize response",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = try #require(responseObject["error"] as? [String: Any])
        #expect(error["message"] as? String == "unsupported upstream protocol version")
        #expect(manager.hasSession(id: sessionID) == false)
        #expect(manager.isInitialized() == false)
    }

    @Test func sessionManagerRemovesPendingInitializeSessionOnFailure() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-failed-initialize"
        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        manager.failInitPending(error: TimeoutError())

        do {
            _ = try await future.get()
            #expect(Bool(false), "initialize future should fail")
        } catch {
            #expect(manager.hasSession(id: sessionID) == false)
        }
    }

    @Test func sessionManagerRecordsServerInitiatedRequestUpstreamForClientResponses()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-server-request"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "server-request-1",
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        let serverRequestData = try JSONSerialization.data(
            withJSONObject: serverRequest,
            options: []
        )
        manager.routeUnmappedUpstreamMessage(serverRequestData, upstreamIndex: 0)

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        let route = try #require(session.serverRequestTracker.consume(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.key == "server-request-1")
        #expect(session.serverRequestTracker.consume(clientID: clientID) == nil)
    }

    @Test func sessionManagerDoesNotTreatServerRequestIDAsPendingResponseID()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-server-request-id-collision"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let originalID = JSONRPC.ID(any: NSNumber(value: 42))!
        let responseFuture = session.router.registerRequest(
            idKey: originalID.key,
            on: eventLoop
        )
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: serverRequest, options: []),
            upstreamIndex: 0
        )

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        let route = try #require(session.serverRequestTracker.consume(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.key == String(upstreamID))

        manager.routeUpstreamMessage(try makeToolListResponse(id: upstreamID), upstreamIndex: 0)
        _ = try await responseFuture.get()
    }

    @Test func sessionManagerRoutesServerRequestFromMixedUpstreamBatchThroughTracker()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-mixed-upstream-batch"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let originalID = JSONRPC.ID(any: NSNumber(value: 42))!
        let responseFuture = session.router.registerRequest(
            idKey: originalID.key,
            on: eventLoop
        )
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        let batch: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": NSNumber(value: upstreamID),
                "result": ["ok": true],
            ],
            [
                "jsonrpc": "2.0",
                "id": "server-request-1",
                "method": "sampling/createMessage",
                "params": [String: Any](),
            ],
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: batch, options: []),
            upstreamIndex: 0
        )

        let response = try decodeJSON(from: try await responseFuture.get())
        #expect((response["id"] as? NSNumber)?.intValue == 42)
        #expect((response["result"] as? [String: Any])?["ok"] as? Bool == true)

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        let route = try #require(session.serverRequestTracker.lookup(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.key == "server-request-1")

        let clientResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": clientID.value.foundationObject,
            "result": ["accepted": true],
        ]
        let forwardingResult = try await manager.forwardServerRequestResponse(
            responseData: try JSONSerialization.data(withJSONObject: clientResponse, options: []),
            sessionID: sessionID,
            responseID: clientID,
            on: eventLoop
        ).get()
        #expect(forwardingResult == .accepted)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) == nil)

        let forwarded = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let forwardedObject = try #require(
            JSONSerialization.jsonObject(with: forwarded, options: []) as? [String: Any]
        )
        #expect(forwardedObject["id"] as? String == "server-request-1")
        #expect((forwardedObject["result"] as? [String: Any])?["accepted"] as? Bool == true)
    }

    @Test func sessionManagerCompletesMalformedMappedUpstreamResponseWithError()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-malformed-mapped-response"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let originalID = JSONRPC.ID(any: NSNumber(value: 42))!
        let responseFuture = session.router.registerRequest(
            idKey: originalID.key,
            on: eventLoop
        )
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )
        let malformedResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
        ]

        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: malformedResponse, options: []),
            upstreamIndex: 0
        )

        let response = try decodeJSON(from: try await responseFuture.get())
        #expect((response["id"] as? NSNumber)?.intValue == 42)
        let error = try #require(response["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32000)
        #expect(error["message"] as? String == "invalid upstream response")
    }

    @Test func sessionManagerPreservesServerRequestRouteUntilForwardingSendAccepted()
        async throws
    {
        let upstream = ToggleableOverloadUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-server-response-retry"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "server-request-1",
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        manager.routeUnmappedUpstreamMessage(
            try JSONSerialization.data(withJSONObject: serverRequest, options: []),
            upstreamIndex: 0
        )

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        #expect(session.serverRequestTracker.lookup(clientID: clientID) != nil)

        let clientResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": clientID.value.foundationObject,
            "result": ["ok": true],
        ]
        let clientResponseData = try JSONSerialization.data(
            withJSONObject: clientResponse,
            options: []
        )

        await upstream.overloadNextSend()
        let rejectedResult = try await manager.forwardServerRequestResponse(
            responseData: clientResponseData,
            sessionID: sessionID,
            responseID: clientID,
            on: eventLoop
        ).get()
        #expect(rejectedResult == .upstreamUnavailable)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) != nil)

        let acceptedResult = try await manager.forwardServerRequestResponse(
            responseData: clientResponseData,
            sessionID: sessionID,
            responseID: clientID,
            on: eventLoop
        ).get()
        #expect(acceptedResult == .accepted)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) == nil)

        let forwarded = try await upstream.nextSent(at: 3)
        let forwardedObject = try #require(
            JSONSerialization.jsonObject(with: forwarded, options: []) as? [String: Any]
        )
        #expect(forwardedObject["id"] as? String == "server-request-1")
    }

    @Test func serverRequestTrackerPreservesDuplicateUpstreamIDsAcrossUpstreams()
        async throws
    {
        let tracker = ServerRequestTracker()
        let upstreamID = JSONRPC.ID(any: "duplicate")!

        let firstClientID = tracker.record(upstreamID: upstreamID, upstreamIndex: 0)
        let secondClientID = tracker.record(upstreamID: upstreamID, upstreamIndex: 1)

        #expect(firstClientID.key != secondClientID.key)
        let firstRoute = try #require(tracker.consume(clientID: firstClientID))
        let secondRoute = try #require(tracker.consume(clientID: secondClientID))
        #expect(firstRoute.upstreamIndex == 0)
        #expect(secondRoute.upstreamIndex == 1)
        #expect(firstRoute.upstreamID.key == "duplicate")
        #expect(secondRoute.upstreamID.key == "duplicate")
    }

    @Test func serverRequestTrackerExpiresUnansweredRoutes() async throws {
        let tracker = ServerRequestTracker(routeTimeout: .seconds(1))
        let upstreamID = JSONRPC.ID(any: "stale")!
        let now = Date()

        let clientID = tracker.record(
            upstreamID: upstreamID,
            upstreamIndex: 0,
            now: now
        )

        let expired = tracker.consume(
            clientID: clientID,
            now: now.addingTimeInterval(2)
        )
        #expect(expired == nil)
    }

    @Test func serverRequestTrackerEvictsOldestRoutesAtCapacity() async throws {
        let tracker = ServerRequestTracker(routeTimeout: .seconds(60), maxRoutes: 2)
        let now = Date()
        let first = tracker.record(
            upstreamID: JSONRPC.ID(any: "first")!,
            upstreamIndex: 0,
            now: now
        )
        let second = tracker.record(
            upstreamID: JSONRPC.ID(any: "second")!,
            upstreamIndex: 0,
            now: now
        )
        let third = tracker.record(
            upstreamID: JSONRPC.ID(any: "third")!,
            upstreamIndex: 0,
            now: now
        )

        #expect(tracker.consume(clientID: first, now: now) == nil)
        #expect(tracker.consume(clientID: second, now: now)?.upstreamID.key == "second")
        #expect(tracker.consume(clientID: third, now: now)?.upstreamID.key == "third")
    }

    @Test func sessionManagerRoutesServerInitiatedRequestToOwningSession() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let firstSessionID = "session-server-request-a"
        let firstSession = manager.session(id: firstSessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: firstSessionID)

        let secondSessionID = "session-server-request-b"
        let secondSession = manager.session(id: secondSessionID)
        let secondFuture = fixture.registerInitialize(requestID: 2, sessionID: secondSessionID)
        _ = try await secondFuture.get()

        let ownerLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: secondSessionID,
                label: "tools/call:owner",
                isBatch: false,
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            ownerLeaseID,
            requestIDKey: "owner",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        defer { manager.completeRequestLease(ownerLeaseID) }

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "server-request-1",
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        let serverRequestData = try JSONSerialization.data(
            withJSONObject: serverRequest,
            options: []
        )
        manager.routeUnmappedUpstreamMessage(serverRequestData, upstreamIndex: 0)

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        #expect(firstSession.serverRequestTracker.consume(clientID: clientID) == nil)
        let route = try #require(secondSession.serverRequestTracker.consume(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.key == "server-request-1")
    }

    @Test func sessionManagerRestoresPendingInitializeWhenInitializedNotificationOverloads()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initialInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream.overloadNextInitializedNotificationSend()
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await upstream.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        _ = try await future.get()
    }

    @Test func sessionManagerCancelsOriginalInitTimeoutBeforeRetryingInitializedNotificationOverload()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let timeoutClock = TestClock()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock)
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initialInitialize = try #require(await upstream.sentValue(at: 0))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream.overloadNextInitializedNotificationSend()
        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .milliseconds(150))
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try #require(await upstream.sentValue(at: 2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .milliseconds(180))
        await upstream.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil, "initializeResponse=\(response)")
    }

    @Test func sessionManagerRunsSecondaryWarmupAfterRecoveredInitializedNotification()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initialInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await upstream0.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil, "initializeResponse=\(response)")
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 5)
        let warmInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        #expect(methodName(from: warmInitialize) == "initialize")
    }

    @Test func sessionManagerSecondaryWarmInitRetriesWhenInitializedNotificationSendOverloads()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let primaryInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let primaryUpstreamID = try extractUpstreamID(from: primaryInitialize)
        await upstream0.yield(.message(try makeInitializeResponse(id: primaryUpstreamID)))
        _ = try await initFuture.get()

        let firstWarmInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let firstWarmUpstreamID = try extractUpstreamID(from: firstWarmInitialize)
        await upstream1.overloadNextInitializedNotificationSend()
        await upstream1.yield(.message(try makeInitializeResponse(id: firstWarmUpstreamID)))

        try await waitForSentCount(upstream1, count: 3, timeoutSeconds: 2)
        let rejectedInitialized = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        #expect(methodName(from: rejectedInitialized) == "notifications/initialized")
        let retriedWarmInitialize = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        #expect(methodName(from: retriedWarmInitialize) == "initialize")
    }

    @Test func sessionManagerBuffersUnmappedNotificationsAfterInitializeUntilNotificationClientConnects()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )
        _ = try await future.get()
        let notificationEventIndex = upstreamEvents.count()
        await upstream.yield(.message(notification))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for cached initialize notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received.count == 1)
        #expect(received.first == notification)

        manager.markNotificationClientConnected(sessionID: sessionID)
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerRoutesUnmappedNotificationsDuringInitializeHandshake() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-handshake"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 99],
            ],
            options: []
        )
        let notificationEventIndex = upstreamEvents.count()
        await upstream.yield(.message(notification))

        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for initialize-handshake notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received.count == 1)
        #expect(received.first == notification)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await future.get()
    }

    @Test func sessionManagerBuffersUnmappedNotificationsForCachedInitializeSessionsUntilClientConnects()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let firstFuture = manager.registerInitialize(
            sessionID: "session-A",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let firstSent = await upstream.sent()
        let firstInitID = try extractUpstreamID(from: firstSent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: firstInitID)))
        _ = try await firstFuture.get()

        let sessionID = "session-B"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()
        let cachedFuture = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 2],
            ],
            options: []
        )
        let notificationEventIndex = upstreamEvents.count()
        await upstream.yield(.message(notification))

        _ = try await cachedFuture.get()
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for cached initialize session notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received.count == 1)
        #expect(received.first == notification)

        manager.markNotificationClientConnected(sessionID: sessionID)
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDoesNotRecreateRemovedSessionWhenInitializeCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-removed"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))

        _ = try await future.get()
        #expect(manager.hasSession(id: sessionID) == false)
    }

    @Test func sessionManagerDoesNotApplyRemovedInitializeStateToRecreatedSession() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)
        let replacement = manager.session(id: sessionID)
        _ = replacement.router.drainBufferedNotifications()

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 7],
            ],
            options: []
        )
        _ = try await future.get()
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(replacement.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerRoutesUnmappedNotificationsToCachedInitializeSessionsUntilClientConnects()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-hinted-pin"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        _ = try await future.get()

        let notification0 = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 0],
            ],
            options: []
        )
        let notification1 = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )
        let eventIndex = upstreamEvents.count()
        await upstream0.yield(.message(notification0))
        await upstream1.yield(.message(notification1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: eventIndex,
            description: "waiting for first cached initialize notification"
        )
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: eventIndex + 1,
            description: "waiting for second cached initialize notification"
        )

        let received = session.router.drainBufferedNotifications()
        #expect(Set(received) == Set([notification0, notification1]))

        manager.markNotificationClientConnected(sessionID: sessionID)
        manager.routeUpstreamMessage(notification0, upstreamIndex: 0)
        manager.routeUpstreamMessage(notification1, upstreamIndex: 1)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerTimeoutResetsInitState() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutClock = TestClock()
        let config = makeConfig(requestTimeout: 1)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock)
        )
        defer { manager.shutdownAndWait() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for initial initialize request"
        )
        #expect((await upstream.sent()).count == 1)

        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .seconds(1))
        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }
        #expect(manager.testStateSnapshot().initInFlight == false)

        _ = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await spinUntilSentCount(
            upstream,
            count: 2,
            description: "waiting for second initialize request after timeout reset"
        )
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerShutdownFailsPendingInitializeRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        await manager.shutdown()

        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
    }

    @Test func sessionManagerTimeoutDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.1)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-timeout-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        let replacementSnapshotBeforeTimeout = try #require(manager.testSessionSnapshot(id: sessionID))

        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }

        let replacementSnapshotAfterTimeout = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterTimeout.generation == replacementSnapshotBeforeTimeout.generation)
    }

    @Test func sessionManagerInitializeErrorDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-error-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        let replacementSnapshotBeforeError = try #require(manager.testSessionSnapshot(id: sessionID))

        await upstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": initID,
                        "error": [
                            "code": -32000,
                            "message": "boom",
                        ],
                    ],
                    options: []
                )
            )
        )

        let response = try decodeJSON(from: try await future.get())
        let errorObject = try #require(response["error"] as? [String: Any])
        #expect(errorObject["message"] as? String == "boom")

        let replacementSnapshotAfterError = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterError.generation == replacementSnapshotBeforeError.generation)
    }

    @Test func sessionManagerSharedToolsListTimeoutStartsFreshControlPlaneLoad() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-timeout"
        _ = manager.session(id: sessionID)

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerSharedToolsListReusesInFlightPrewarm() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.refreshToolsListIfNeeded()
        let prewarmRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: prewarmRequest) == "tools/list")

        let sessionID = "session-tools-prewarm"
        _ = manager.session(id: sessionID)
        let foregroundTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(1)
            )
        }

        try await waitWithTimeout("waiting for foreground tools/list waiter to reuse prewarm load") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        #expect(await upstream.sentCount() == 3)

        let prewarmUpstreamID = try extractUpstreamID(from: prewarmRequest)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": prewarmUpstreamID,
            "result": ["tools": []],
        ]
        await upstream.yield(.message(try JSONSerialization.data(withJSONObject: response)))

        let result = try await foregroundTask.value
        guard case .object(let object) = result else {
            Issue.record("tools/list result should be an object")
            return
        }
        #expect(object["tools"] != nil)
    }

    @Test func sessionManagerSharedToolsListPromotesPartlyConsumedSharedTimeout()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-promote-same-timeout"
        _ = manager.session(id: sessionID)

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")

        firstTask.cancel()
        secondTask.cancel()

        do {
            _ = try await firstTask.value
            Issue.record("first tools/list waiter should be cancelled after promotion test")
        } catch is CancellationError {
        } catch is TimeoutError {
        } catch {
            Issue.record("expected CancellationError or TimeoutError for first waiter but received \(error)")
        }
        do {
            _ = try await secondTask.value
            Issue.record("second tools/list waiter should be cancelled after promotion test")
        } catch is CancellationError {
        } catch is TimeoutError {
        } catch {
            Issue.record("expected CancellationError or TimeoutError for second waiter but received \(error)")
        }
    }

    @Test func sessionManagerSharedToolsListCancellationCancelsLastWaiterLoad() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-cancel"
        _ = manager.session(id: sessionID)
        let task = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerSharedToolsListStopsPromotingAfterLoadBecomesShared() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-shared-no-starvation"
        _ = manager.session(id: sessionID)

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let thirdTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitWithTimeout("waiting for third tools/list waiter to share the in-flight load") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 3
            }
        }
        #expect(await upstream.sentCount() == 4)

        firstTask.cancel()
        secondTask.cancel()
        thirdTask.cancel()
        _ = try? await firstTask.value
        _ = try? await secondTask.value
        _ = try? await thirdTask.value
    }

    @Test func sessionManagerPromotedToolsListCancellationRemovesMigratedWaiter() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-promoted-cancel"
        _ = manager.session(id: sessionID)
        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            Issue.record("first promoted tools/list waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted waiter but received \(error)")
        }

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted tools/list waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted waiter but received \(error)")
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerSharedToolsListTimeoutCancelsStalePrewarmLoad() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = true
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.refreshToolsListIfNeeded()
        let prewarmRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: prewarmRequest) == "tools/list")

        let sessionID = "session-tools-prewarm-timeout"
        _ = manager.session(id: sessionID)
        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitWithTimeout("waiting for foreground tools/list waiter to attach to prewarm load") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5),
            suspendedSleepers: 2
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerLateToolsListResponseDoesNotReseedCanonicalCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-late-response"
        _ = manager.session(id: sessionID)
        let task = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let toolsRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let toolsUpstreamID = try extractUpstreamID(from: toolsRequest)

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        do {
            _ = try await task.value
            Issue.record("tools/list should fail when the only upstream exits")
        } catch {
        }

        let lateResponse = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": toolsUpstreamID,
                "result": ["tools": []],
            ],
            options: []
        )
        manager.routeUpstreamMessage(lateResponse, upstreamIndex: 0)

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerLiveXcodeListWindowsTimeoutStartsFreshControlPlaneLoad()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/call")
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/call")
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerToolsListUnionsProcessRouteCatalogsAndPrefersLatestDescriptor()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let latestUpstream = TestUpstreamClient()
        let olderUpstream = TestUpstreamClient()
        let latestTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [latestUpstream, olderUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: latestTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-union",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let latestRequest = try await latestUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        #expect(methodName(from: latestRequest) == "tools/list")
        let olderRequest = try await olderUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        #expect(methodName(from: olderRequest) == "tools/list")
        await olderUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: olderRequest),
                    tools: [
                        toolDescriptor(name: "SharedTool", description: "from-26"),
                        toolDescriptor(name: "Only26", description: "old-only"),
                    ],
                )
            )
        )
        await latestUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: latestRequest),
                    tools: [
                        toolDescriptor(name: "SharedTool", description: "from-27"),
                        toolDescriptor(name: "Only27", description: "new-only"),
                    ],
                )
            )
        )

        let result = try await waitWithTimeout("waiting for process-routed tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["Only26", "Only27", "SharedTool"])
        #expect(toolDescription(in: result, name: "SharedTool") == "from-27")
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 0)
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult(forUpstreamIndex: 1) ?? .null))
                == Set(["Only26", "SharedTool"])
        )

        let catalogs = manager.debugSnapshot().processToolCatalogs
        #expect(catalogs.count == 2)
        let latestCatalog = try #require(catalogs.first { $0.processID == latestTarget.processID })
        #expect(latestCatalog.toolCount == 2)
        #expect(latestCatalog.tabOwnerCount == 0)
        #expect(latestCatalog.workspaceOwnerCount == 0)
        #expect(latestCatalog.isCanonicalSource)
        #expect(latestCatalog.exposurePolicy == "union_latest_xcode_descriptor_runtime_guard")
        #expect(latestCatalog.extraBeyondExposedCatalog == ["Only26"])
        #expect(latestCatalog.schemaConflicts == ["SharedTool"])
    }

    @Test func sessionManagerToolsListSkipsUnavailableProcessRouteCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badUpstream = TestUpstreamClient()
        let goodUpstream = TestUpstreamClient()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [badUpstream, goodUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_no_workspace"
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-skip",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let goodRequest = try await goodUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        await goodUpstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": try extractUpstreamID(from: goodRequest),
                        "result": [
                            "tools": [
                                [
                                    "name": "XcodeRead",
                                    "description": "read",
                                ],
                            ],
                        ],
                    ],
                    options: []
                )
            )
        )

        let result = try await waitWithTimeout("waiting for process-routed tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["XcodeRead"])
        #expect(await badUpstream.sentCount() == 0)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["XcodeRead"])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
    }

    @Test func sessionManagerToolsListRetriesSiblingBeforeDroppingProcessCatalog()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80433, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [unavailableUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-sibling-retry",
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        await siblingUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    tools: [
                        toolDescriptor(name: "SiblingTool"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for sibling process tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["SiblingTool"])
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
            target.processID,
        ])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(manager.documentationCandidateProcessOrder() == [target.processID])
    }

    @Test func sessionManagerToolsListSiblingRetryUsesSharedDeadline()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let firstUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80434, xcodeVersion: "27.0")
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [firstUpstream, siblingUpstream],
            clock: clocks.clock,
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(
                clock: clocks.timeoutClock
            ),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-sibling-deadline",
                requestTimeoutOverride: .milliseconds(100)
            )
        }

        _ = try await sentValue(from: firstUpstream, at: 0, timeout: .seconds(2))
        await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .milliseconds(100)
        )

        do {
            _ = try await waitWithTimeout("waiting for shared deadline timeout") {
                try await task.value
            }
            Issue.record("expected tools/list to fail when sibling deadline is exhausted")
        } catch {
            #expect(error is TimeoutError)
        }
        #expect(await siblingUpstream.sentCount() == 0)
    }

    @Test func sessionManagerProcessToolsListPropagatesCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 80435, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 80436, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-cancel",
                requestTimeoutOverride: .seconds(5)
            )
        }

        _ = try await upstream0.nextSent {
            methodName(from: $0) == "tools/list"
        }
        _ = try await upstream1.nextSent {
            methodName(from: $0) == "tools/list"
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func sessionManagerToolsListClearsSiblingCanonicalCatalogWhenProcessRouteUnavailable()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80431, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let catalog = try jsonValue([
            "tools": [
                toolDescriptor(name: "StaleSiblingOnlyTool"),
            ],
        ])
        manager.processToolCatalogRegistry.record(
            target: target,
            upstreamIndex: 1,
            associatedUpstreamIndices: [0, 1],
            rawResult: catalog
        )
        manager.setCachedToolsListResult(catalog, sourceUpstream: 1)

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_process_route_unavailable"
        )

        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
    }

    @Test func sessionManagerToolsListResyncsRemainingCatalogWhenProcessRouteUnavailable()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80432, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66336, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (badTarget, 0, [toolDescriptor(name: "BadOnlyTool")]),
                (goodTarget, 1, [toolDescriptor(name: "GoodOnlyTool")]),
            ]
        )
        #expect(manager.cachedToolsListResult() != nil)

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_process_route_unavailable"
        )

        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["GoodOnlyTool"])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [goodTarget.processID]
        )
        #expect(manager.canonicalBrokerState.toolsSourceUpstream() == 1)
    }

    @Test func sessionManagerToolsListDoesNotFallbackWhenAllProcessRoutesUnavailable()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 66335, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_unavailable"
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            _ = try await manager.sharedToolsList(
                sessionID: "session-process-catalog-all-unavailable",
                requestTimeoutOverride: .seconds(5)
            )
        }
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerToolsListSkipsColdProcessRouteCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let coldUpstream = TestUpstreamClient()
        let warmUpstream = TestUpstreamClient()
        let coldTarget = xcodeProcessTarget(processID: 80423, xcodeVersion: "27.0")
        let warmTarget = xcodeProcessTarget(processID: 66334, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [coldUpstream, warmUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: coldTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: warmTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-skip-cold",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let warmRequest = try await warmUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        await warmUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: warmRequest),
                    tools: [
                        toolDescriptor(name: "WarmOnlyTool"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for warm process tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["WarmOnlyTool"])
        #expect(await coldUpstream.sentCount() == 0)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [warmTarget.processID])

        manager.markUpstreamInitialized(upstreamIndex: 0)
        let reloadTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-after-cold-warms",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let coldRequest = try await coldUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        let warmReloadRequest = try await sentValue(
            from: warmUpstream,
            at: 1,
            timeout: .seconds(2)
        )
        #expect(methodName(from: warmReloadRequest) == "tools/list")
        await coldUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: coldRequest),
                    tools: [
                        toolDescriptor(name: "ColdOnlyTool"),
                    ]
                )
            )
        )
        await warmUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: warmReloadRequest),
                    tools: [
                        toolDescriptor(name: "WarmOnlyTool"),
                    ]
                )
            )
        )

        let reloaded = try await waitWithTimeout("waiting for complete process tools/list") {
            try await reloadTask.value
        }
        #expect(toolNames(in: reloaded) == ["ColdOnlyTool", "WarmOnlyTool"])
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == [
            "ColdOnlyTool",
            "WarmOnlyTool",
        ])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 0)
    }

    @Test func sessionManagerToolsListDropsStaleProcessCatalogAfterRefreshFailure()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let staleUpstream = TestUpstreamClient()
        let freshUpstream = TestUpstreamClient()
        let staleTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let freshTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [staleUpstream, freshUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: staleTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: freshTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (staleTarget, 0, [toolDescriptor(name: "Stale27Only")]),
                (freshTarget, 1, [toolDescriptor(name: "Old26Tool")]),
            ]
        )
        manager.canonicalBrokerState.clearToolsCatalog()

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-refresh-failure",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let staleRequest = try await staleUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        let freshRequest = try await freshUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        await staleUpstream.yield(
            .message(
                try makeJSONRPCResponse(
                    id: try extractUpstreamID(from: staleRequest),
                    result: ["notTools": []]
                )
            )
        )
        await freshUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: freshRequest),
                    tools: [
                        toolDescriptor(name: "Fresh26Tool"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for refreshed tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["Fresh26Tool"])
        #expect(manager.cachedToolsListResult() == nil)
        let catalogs = manager.debugSnapshot().processToolCatalogs
        #expect(catalogs.map(\.processID) == [freshTarget.processID])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
    }

    @Test func documentationCandidatesPreferWorkspaceOwnersButKeepFallbackProcesses()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-good, workspacePath: /tmp/Good.xcworkspace",
            ],
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 1))

        #expect(
            manager.documentationCandidateProcessOrder() == [
                goodTarget.processID,
                badTarget.processID,
            ]
        )
        #expect(
            manager.documentationCandidateProcessIDs() == Set([
                badTarget.processID,
                goodTarget.processID,
            ])
        )
    }

    @Test func documentationCandidatesSkipUnavailableWorkspaceOwner() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-good, workspacePath: /tmp/Good.xcworkspace",
            ],
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 1))
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_owner_terminated"
        )

        #expect(manager.documentationCandidateProcessOrder() == [badTarget.processID])
    }

    @Test func runtimeDocumentationDiscoveryKeepsLiveTargetsOutsideRuntimeRoutes()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let staleTarget = xcodeProcessTarget(processID: 80424, xcodeVersion: "27.0")
        let relaunchedTarget = xcodeProcessTarget(processID: 80425, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: staleTarget, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_relaunch"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [relaunchedTarget]),
            runtimeBox: runtimeBox
        )

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            relaunchedTarget.processID,
        ])
    }

    @Test func runtimeDocumentationDiscoveryDoesNotReaddUnavailableRuntimeRouteTargets()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableTarget = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let outsideTarget = xcodeProcessTarget(processID: 80427, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unavailableTarget, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_route_unavailable"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [unavailableTarget, outsideTarget]),
            runtimeBox: runtimeBox
        )

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            outsideTarget.processID,
        ])
    }

    @Test func sessionManagerFansOutXcodeListWindowsAcrossProcessRoutesAndCachesOwners()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 510, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 511, xcodeVersion: "26.6")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        await upstream0.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init0)))
        )
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        await upstream1.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init1)))
        )
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request0) == "tools/call")
        #expect(toolCallName(from: request0) == "XcodeListWindows")
        let message0 = "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"

        let request1 = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request1) == "tools/call")
        #expect(toolCallName(from: request1) == "XcodeListWindows")
        let message1 = "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: message0
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: message1
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let mergedMessage)? = structuredContent["message"] else {
            Issue.record("expected merged XcodeListWindows structuredContent")
            return
        }
        #expect(mergedMessage == "\(message0)\n\(message1)")

        let tabARequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-a",
                ],
            ],
        ]
        let tabBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-b",
                ],
            ],
        ]
        let workspaceBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeSomeWorkspaceScopedTool",
                "arguments": [
                    "workspacePath": "/Work/B.xcworkspace",
                ],
            ],
        ]
        #expect(manager.preferredUpstreamIndex(for: tabARequest) == 0)
        #expect(manager.preferredUpstreamIndex(for: tabBRequest) == 1)
        #expect(manager.preferredUpstreamIndex(for: workspaceBRequest) == 1)
        #expect(manager.preferredUpstreamIndex(for: [tabARequest, tabBRequest]) == nil)
    }

    @Test func sessionManagerXcodeListWindowsRetriesSiblingBeforeDroppingProcessRoute()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 515, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [unavailableUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: siblingRequest) == "XcodeListWindows")
        let message = "* tabIdentifier: tab-sibling, workspacePath: /Work/S.xcworkspace"
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    message: message
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let resultMessage)? = structuredContent["message"] else {
            Issue.record("expected XcodeListWindows structuredContent")
            return
        }
        #expect(resultMessage == message)
        #expect(manager.documentationCandidateProcessOrder() == [target.processID])
        #expect(manager.preferredUpstreamIndex(for: [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-sibling",
                ],
            ],
        ]) == 1)
    }

    @Test func sessionManagerXcodeListWindowsRetriesSiblingAfterToolError()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let firstUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 516, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [firstUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let firstRequest = try await sentValue(from: firstUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: firstRequest) == "XcodeListWindows")
        await firstUpstream.yield(
            .message(
                try makeXcodeListWindowsToolErrorResponse(
                    id: try extractUpstreamID(from: firstRequest),
                    message: "XcodeListWindows failed"
                )
            )
        )

        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: siblingRequest) == "XcodeListWindows")
        let message = "* tabIdentifier: tab-tool-error, workspacePath: /Work/T.xcworkspace"
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    message: message
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let resultMessage)? = structuredContent["message"] else {
            Issue.record("expected XcodeListWindows structuredContent")
            return
        }
        #expect(resultMessage == message)
        #expect(manager.documentationCandidateProcessOrder() == [target.processID])
        #expect(manager.preferredUpstreamIndex(for: [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-tool-error",
                ],
            ],
        ]) != nil)
    }

    @Test func sessionManagerCachesDuplicateWorkspaceOwnerByRoutePriority() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 512, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 513, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        await upstream0.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init0)))
        )
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        await upstream1.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init1)))
        )
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let request1 = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        let workspacePath = "/Work/Shared.xcworkspace"
        let message0 = "* tabIdentifier: tab-a, workspacePath: \(workspacePath)"
        let message1 = "* tabIdentifier: tab-b, workspacePath: \(workspacePath)"
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: message0
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: message1
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let mergedMessage)? = structuredContent["message"] else {
            Issue.record("expected merged XcodeListWindows structuredContent")
            return
        }
        #expect(mergedMessage == "\(message0)\n\(message1)")

        let workspaceRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeSomeWorkspaceScopedTool",
                "arguments": [
                    "workspacePath": workspacePath,
                ],
            ],
        ]
        #expect(manager.preferredUpstreamIndex(for: workspaceRequest) == 0)
    }

    @Test func sessionManagerSkipsUninitializedProcessRoutesDuringWindowFanout()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 514, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 515, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let firstUpstream0StartIndex = await upstream0.sentCount()
        let firstUpstream1StartIndex = await upstream1.sentCount()
        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let firstRequest = try await waitWithTimeout(
            "waiting for first window fanout request on upstream0",
            timeout: .seconds(2)
        ) {
            try await upstream0.nextSent(startingAt: firstUpstream0StartIndex) {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        }
        #expect(await upstream1.sentCount() == firstUpstream1StartIndex)
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: firstRequest),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for first window fanout result",
            timeout: .seconds(2)
        ) {
            try await firstTask.value
        }
        #expect(await upstream1.sentCount() == firstUpstream1StartIndex)

        manager.markUpstreamInitialized(upstreamIndex: 1)
        let secondUpstream0StartIndex = await upstream0.sentCount()
        let secondUpstream1StartIndex = await upstream1.sentCount()
        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let secondRequest0 = try await waitWithTimeout(
            "waiting for second window fanout request on upstream0",
            timeout: .seconds(2)
        ) {
            try await upstream0.nextSent(startingAt: secondUpstream0StartIndex) {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        }
        let secondRequest1 = try await waitWithTimeout(
            "waiting for second window fanout request on upstream1",
            timeout: .seconds(2)
        ) {
            try await upstream1.nextSent(startingAt: secondUpstream1StartIndex) {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: secondRequest0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: secondRequest1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for second window fanout result",
            timeout: .seconds(2)
        ) {
            try await secondTask.value
        }
    }

    @Test func mergedXcodeListWindowsPreservesToolErrors() throws {
        let successMessage = "* tabIdentifier: tab-ok, workspacePath: /Work/OK.xcworkspace"
        let success = try jsonValue([
            "content": [
                [
                    "type": "text",
                    "text": "{\"message\":\"\(successMessage)\"}",
                ],
            ],
            "structuredContent": [
                "message": successMessage,
            ],
        ])
        let error = try jsonValue([
            "content": [
                [
                    "type": "text",
                    "text": "XcodeListWindows failed",
                ],
            ],
            "isError": true,
        ])

        let partialMerge = try #require(
            RuntimeCoordinator.mergedXcodeListWindowsResult([error, success])
        )
        guard case .object(let partialObject) = partialMerge,
              case .object(let structuredContent)? = partialObject["structuredContent"],
              case .string(let mergedMessage)? = structuredContent["message"] else {
            Issue.record("expected merged success result")
            return
        }
        #expect(mergedMessage == successMessage)

        let failedMerge = try #require(
            RuntimeCoordinator.mergedXcodeListWindowsResult([error])
        )
        guard case .object(let failedObject) = failedMerge else {
            Issue.record("expected tool error result")
            return
        }
        guard case .bool(true)? = failedObject["isError"] else {
            Issue.record("expected merged failure to preserve isError")
            return
        }
    }

    @Test func sessionManagerKeepsWindowlessProcessRouteAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 600, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 601, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: /Work/Stale.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: ""
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        _ = try await task.value

        let processIDs = Set(manager.debugSnapshot().processToolCatalogs.map(\.processID))
        #expect(processIDs == Set([Int32(target0.processID), Int32(target1.processID)]))
        #expect(
            manager.documentationCandidateProcessIDs() == Set([
                target0.processID,
                target1.processID,
            ])
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1001,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == nil
        )
    }

    @Test func ownerBoundRefreshSkipsUnavailableProcessRoutes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 602, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 603, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 1002,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-b"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected refreshed owner-bound request to forward")
            return
        }
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundRefreshUsesUsableSiblingWhenPrimaryUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let primaryUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 604, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [primaryUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 1003,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-sibling"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request = try await siblingUpstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await primaryUpstream.sentCount() == 0)
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: tab-sibling, workspacePath: /Work/S.xcworkspace"
                )
            )
        )

        let decision = await task.value
        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected refreshed owner-bound request to forward through sibling")
            return
        }
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolWithoutOwnerHintRoutesWhenSingleProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 605, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 1004,
                name: "BuildProject",
                arguments: [:]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected owner-bound request without hint to use single process")
            return
        }
        #expect(preferredUpstreamIndices == [0])
        #expect(await upstream.sentCount() == 0)
    }

    @Test func ownerBoundToolWithoutOwnerHintRoutesWhenSingleCatalogCandidate() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 606, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 607, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [toolDescriptor(name: "XcodeRead")]),
            ]
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 1005,
                name: "BuildProject",
                arguments: [:]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected owner-bound request without hint to use only catalog candidate")
            return
        }
        #expect(preferredUpstreamIndices == [0])
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func ownerBoundToolRoutesToCachedWindowOwner() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 610, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 611, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 101,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected owner-bound request to forward")
            return
        }
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func ownerBoundToolRoutesToUsableSlotInOwningProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 612, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 109,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected owner-bound request to forward")
            return
        }
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundProcessRouteUsesIdleSiblingWhenPrimaryIsBusy() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 614, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 112,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected owner-bound route to expose process slot candidates")
            return
        }
        #expect(preferredUpstreamIndices == [0, 1])

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:LongRunningBuild",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedUpstreamIndex in
            #expect(selectedUpstreamIndex == 0)
            return activePromise.futureResult
        }

        let routedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-routed",
            label: "tools/call:BuildProject",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let routedLeaseID = manager.createRequestLease(descriptor: routedDescriptor)
        let selectedUpstream = NIOLockedValueBox<Int?>(nil)
        let routedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: routedLeaseID,
            descriptor: routedDescriptor,
            on: eventLoop,
            preferredUpstreamIndices: preferredUpstreamIndices
        ) { selectedUpstreamIndex in
            selectedUpstream.withLockedValue { $0 = selectedUpstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        _ = try await routedFuture.get()
        #expect(selectedUpstream.withLockedValue { $0 } == 1)
        manager.completeRequestLease(routedLeaseID)

        manager.completeRequestLease(activeLeaseID)
        activePromise.succeed(())
        _ = try await activeFuture.get()
    }

    @Test func ownerBoundToolKeepsProcessRouteWhenSiblingSlotExits() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 111,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected owner-bound request to use sibling slot")
            return
        }
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func sessionManagerProcessCatalogRepointsCanonicalSourceWhenSourceSlotExits()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "SharedTool")]),
            ]
        )

        #expect(manager.clearUpstreamState(upstreamIndex: 0))

        var snapshot = manager.debugSnapshot()
        let catalog = try #require(snapshot.processToolCatalogs.first)
        #expect(catalog.upstreamIndex == 1)
        #expect(catalog.isCanonicalSource)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["SharedTool"])

        #expect(manager.clearUpstreamState(upstreamIndex: 1))

        snapshot = manager.debugSnapshot()
        #expect(manager.cachedToolsListResult() == nil)
        #expect(snapshot.processToolCatalogs.isEmpty)
    }

    @Test func nonOwnerUnionToolRoutesToCatalogOwnerProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 613, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 614, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "Xcode27OnlyTool")]),
                (target1, 1, [toolDescriptor(name: "SharedTool")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: [
                    "jsonrpc": "2.0",
                    "id": 110,
                    "method": "tools/call",
                    "params": [
                        "name": "Xcode27OnlyTool",
                    ],
                ]
            )
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected union-only tool to forward")
            return
        }
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func publicXcodeListWindowsRoutesToLocalAggregation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 618, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 619, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "XcodeListWindows")]),
                (target1, 1, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 118,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )
        )

        guard case .localXcodeListWindows = decision else {
            Issue.record("expected XcodeListWindows to resolve through local aggregation")
            return
        }
    }

    @Test func publicXcodeListWindowsMixedNonToolBatchIsRejected() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: [
                    toolsCallObject(
                        id: 119,
                        name: "XcodeListWindows",
                        arguments: [:]
                    ),
                    [
                        "jsonrpc": "2.0",
                        "id": 120,
                        "method": "resources/list",
                    ],
                ]
            )
        )

        guard case .reject(let errors, let forceBatchArray) = decision else {
            Issue.record("expected mixed XcodeListWindows batch to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["119"])
        #expect(forceBatchArray)
    }

    @Test func publicXcodeListWindowsNotificationDoesNotRejectOtherRequest() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 621, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    0,
                    [
                        toolDescriptor(name: "XcodeListWindows"),
                        toolDescriptor(name: "XcodeRead"),
                    ]
                ),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: [
                    toolsCallObject(
                        id: nil,
                        name: "XcodeListWindows",
                        arguments: [:]
                    ),
                    toolsCallObject(
                        id: 121,
                        name: "XcodeRead",
                        arguments: ["path": "/tmp/file.swift"]
                    ),
                ]
            )
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected notification-only XcodeListWindows item not to reject batch")
            return
        }
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func publicXcodeListWindowsWithNotificationForwardsWholeBatch() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 622, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    0,
                    [
                        toolDescriptor(name: "XcodeListWindows"),
                        toolDescriptor(name: "XcodeRead"),
                    ]
                ),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: [
                    toolsCallObject(
                        id: 122,
                        name: "XcodeListWindows",
                        arguments: [:]
                    ),
                    toolsCallObject(
                        id: nil,
                        name: "XcodeRead",
                        arguments: ["path": "/tmp/file.swift"]
                    ),
                ]
            )
        )

        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected XcodeListWindows with notification to forward whole batch")
            return
        }
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func ownerBoundBatchRejectsToolMissingFromOwnerProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 616, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 617, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [toolDescriptor(name: "Xcode27OnlyTool")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: [
                toolsCallObject(
                    id: 112,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-a"]
                ),
                toolsCallObject(
                    id: 113,
                    name: "Xcode27OnlyTool",
                    arguments: [:]
                ),
            ],
            requestTimeoutOverride: .seconds(2)
        )

        guard case .reject(let errors, let forceBatchArray) = decision else {
            Issue.record("expected batch with owner-missing tool to reject")
            return
        }
        #expect(forceBatchArray)
        #expect(errors.map(\.id.key) == ["112", "113"])
        #expect(errors.first?.message.contains("not available") == true)
    }

    @Test func ownerBoundToolRefreshesWindowsOnCacheMissBeforeRouting() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 621, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 102,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-b"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        guard case .forwardAny(let preferredUpstreamIndices) = decision else {
            Issue.record("expected refreshed owner-bound request to forward")
            return
        }
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRejectsWhenOwnerCannotBeResolvedAfterRefresh() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 630, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 631, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 103,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "missing-tab"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        guard case .reject(let errors, let forceBatchArray) = decision else {
            Issue.record("expected unresolved owner-bound request to reject")
            return
        }
        #expect(forceBatchArray == false)
        #expect(errors.map(\.id.key) == ["103"])
        #expect(errors.first?.message.contains("unable to resolve Xcode window owner") == true)
    }

    @Test func ownerBoundToolRejectsWhenOwnerProcessLacksTool() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 640, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 641, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "XcodeRead")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 104,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-b"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .reject(let errors, let forceBatchArray) = decision else {
            Issue.record("expected missing owner capability to reject")
            return
        }
        #expect(forceBatchArray == false)
        #expect(errors.map(\.id.key) == ["104"])
        #expect(errors.first?.message.contains("not available") == true)
    }

    @Test func ownerBoundBatchRejectsMixedOwnersButPinsSingleOwner() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 650, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 651, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace\n"
                            + "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-c, workspacePath: /Work/C.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let singleOwnerDecision = await manager.toolRoutingDecision(
            for: [
                toolsCallObject(
                    id: 105,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-a"]
                ),
                toolsCallObject(
                    id: 106,
                    name: "BuildProject",
                    arguments: ["workspacePath": "/Work/B.xcworkspace"]
                ),
            ],
            requestTimeoutOverride: .seconds(2)
        )
        guard case .forwardAny(let preferredUpstreamIndices) = singleOwnerDecision else {
            Issue.record("expected single-owner batch to forward")
            return
        }
        #expect(preferredUpstreamIndices == [0])

        let mixedDecision = await manager.toolRoutingDecision(
            for: [
                toolsCallObject(
                    id: 107,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-a"]
                ),
                toolsCallObject(
                    id: 108,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-c"]
                ),
                toolsCallObject(
                    id: 114,
                    name: "SharedTool",
                    arguments: [:]
                ),
            ],
            requestTimeoutOverride: .seconds(2)
        )
        guard case .reject(let errors, let forceBatchArray) = mixedDecision else {
            Issue.record("expected mixed-owner batch to reject")
            return
        }
        #expect(forceBatchArray)
        #expect(errors.map(\.id.key) == ["107", "108", "114"])
        #expect(errors.allSatisfy { $0.message.contains("mixed Xcode window owners") })
    }

    @Test func sessionManagerLiveXcodeListWindowsCancellationCancelsLastWaiterLoad()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let request = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request) == "tools/call")

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled XcodeListWindows waiter should not complete successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError but received \(error)")
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerPromotedLiveXcodeListWindowsCancellationRemovesMigratedWaiter()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            Issue.record("first promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func controlPlaneRPCHandleCancelBeforeQueueStartCapturesQueuedState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == nil)
        #expect(snapshot?.upstreamIndex == nil)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markRegistered(registrationToken: UUID(), upstreamIndex: 0) == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterRegisterCapturesRegistrationState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, upstreamIndex: 2))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 2)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markAssigned(registrationToken: token, upstreamIndex: 2, requestIDKey: "req") == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterAssignCapturesRequestMappingState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, upstreamIndex: 1))
        #expect(handle.markAssigned(registrationToken: token, upstreamIndex: 1, requestIDKey: "req-1"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 1)
        #expect(snapshot?.requestIDKey == "req-1")
    }

    @Test func controlPlaneRPCHandleCancelAfterSendUsesAssignedSnapshotUntilFinished() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, upstreamIndex: 0))
        #expect(handle.markAssigned(registrationToken: token, upstreamIndex: 0, requestIDKey: "req-after-send"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 0)
        #expect(snapshot?.requestIDKey == "req-after-send")

        handle.markFinished()
        handle.cancel()
        let repeatedSnapshot = cancellation.withLockedValue { $0 }
        #expect(repeatedSnapshot?.requestIDKey == "req-after-send")
    }

    @Test func sessionManagerEagerInitializeRestartsAfterExit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }
        #expect(manager.isInitialized() == false)

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))

        await upstream.yield(.exit(1))
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        _ = manager
    }

    @Test func initializeTimeoutRemainsBoundedWhenRequestTimeoutIsDisabled() throws {
        let timeout = MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: 0)
        #expect(timeout?.nanoseconds == TimeAmount.seconds(60).nanoseconds)
    }

    @Test func controlPlaneTimeoutStaysShortForSlowDiscoveryWork() throws {
        let disabledDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 0)
        #expect(disabledDefault?.nanoseconds == TimeAmount.seconds(10).nanoseconds)

        let longDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 300)
        #expect(longDefault?.nanoseconds == TimeAmount.seconds(10).nanoseconds)

        let shortDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 3)
        #expect(shortDefault?.nanoseconds == TimeAmount.seconds(3).nanoseconds)
    }

    @Test func sessionManagerStillAutoInitializesWhenRequestTimeoutIsDisabled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
    }

    @Test func controlPlaneDoesNotReturnStaleToolsCatalogAfterGenerationClear() async throws {
        let brokerState = CanonicalBrokerState()
        let debugMirror = ControlPlane.DebugMirror()
        let loadStarted = TestSignal()
        let releaseLoad = AsyncGate()
        let coordinator = ControlPlaneCoordinator(
            brokerState: brokerState,
            debugMirror: debugMirror,
            toolsCatalogLoader: { _, _ in
                loadStarted.signal()
                try await releaseLoad.wait()
                return CanonicalToolsCatalogLoadResult(
                    rawResult: .object(["tools": .array([])]),
                    sourceUpstream: 0,
                    durationMilliseconds: 1
                )
            },
            windowsLoader: { _, _, _ in .object([:]) },
            upstreamHandshakeStates: { [:] },
            logger: ProxyLogging.make("control-plane-test"),
            controlPlaneDefaultTimeout: nil
        )

        let task = Task {
            try await coordinator.toolsCatalog(deadlineUptimeNs: nil)
        }
        try await loadStarted.wait(description: "waiting for tools catalog load")
        _ = try await waitWithTimeout("waiting for tools catalog waiter") {
            try await debugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == 1 }
        }

        brokerState.clearToolsCatalog()
        await releaseLoad.signal()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func controlPlaneDoesNotReturnStaleWindowsAfterGenerationClear() async throws {
        let brokerState = CanonicalBrokerState()
        let debugMirror = ControlPlane.DebugMirror()
        let loadStarted = TestSignal()
        let releaseLoad = AsyncGate()
        let coordinator = ControlPlaneCoordinator(
            brokerState: brokerState,
            debugMirror: debugMirror,
            toolsCatalogLoader: { _, _ in
                CanonicalToolsCatalogLoadResult(
                    rawResult: .object(["tools": .array([])]),
                    sourceUpstream: 0,
                    durationMilliseconds: 1
                )
            },
            windowsLoader: { _, _, _ in
                loadStarted.signal()
                try await releaseLoad.wait()
                return .object(["windows": .array([])])
            },
            upstreamHandshakeStates: { [:] },
            logger: ProxyLogging.make("control-plane-test"),
            controlPlaneDefaultTimeout: nil
        )

        let task = Task {
            try await coordinator.listWindows(route: .anyHealthy, deadlineUptimeNs: nil)
        }
        try await loadStarted.wait(description: "waiting for window load")
        _ = try await waitWithTimeout("waiting for window waiter") {
            try await debugMirror.waitForSnapshot { $0.waiterCounts.windows == 1 }
        }

        brokerState.clearInitialize()
        await releaseLoad.signal()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func controlPlaneDelayedInvalidationDoesNotCancelFreshToolsCatalogLoad()
        async throws
    {
        let brokerState = CanonicalBrokerState()
        let debugMirror = ControlPlane.DebugMirror()
        let loadIndexBox = NIOLockedValueBox(0)
        let firstLoadStarted = TestSignal()
        let secondLoadStarted = TestSignal()
        let firstRelease = AsyncGate()
        let secondRelease = AsyncGate()
        let coordinator = ControlPlaneCoordinator(
            brokerState: brokerState,
            debugMirror: debugMirror,
            toolsCatalogLoader: { _, _ in
                let loadIndex = loadIndexBox.withLockedValue { value in
                    value += 1
                    return value
                }
                if loadIndex == 1 {
                    firstLoadStarted.signal()
                    try await firstRelease.wait()
                    return CanonicalToolsCatalogLoadResult(
                        rawResult: .object(["fresh": .bool(false)]),
                        sourceUpstream: 0,
                        durationMilliseconds: 1
                    )
                }
                secondLoadStarted.signal()
                try await secondRelease.wait()
                return CanonicalToolsCatalogLoadResult(
                    rawResult: .object(["fresh": .bool(true)]),
                    sourceUpstream: 0,
                    durationMilliseconds: 1
                )
            },
            windowsLoader: { _, _, _ in .object([:]) },
            upstreamHandshakeStates: { [:] },
            logger: ProxyLogging.make("control-plane-test"),
            controlPlaneDefaultTimeout: nil
        )

        let staleTask = Task {
            try await coordinator.toolsCatalog(deadlineUptimeNs: nil)
        }
        try await firstLoadStarted.wait(description: "waiting for stale tools catalog load")
        _ = try await waitWithTimeout("waiting for stale tools catalog waiter") {
            try await debugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == 1 }
        }

        brokerState.clearToolsCatalog()
        let invalidatedGeneration = brokerState.generation()
        let freshTask = Task {
            try await coordinator.toolsCatalog(deadlineUptimeNs: nil)
        }
        try await secondLoadStarted.wait(description: "waiting for fresh tools catalog load")
        _ = try await waitWithTimeout("waiting for fresh tools catalog waiter") {
            try await debugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == 1 }
        }

        await coordinator.cancelLoadsStartedBeforeGeneration(
            invalidatedGeneration,
            reason: "delayed_invalidation"
        )
        await secondRelease.signal()

        let result = try await freshTask.value
        let object = try #require(result.foundationObject as? [String: Any])
        #expect(object["fresh"] as? Bool == true)
        await #expect(throws: CancellationError.self) {
            _ = try await staleTask.value
        }
        await firstRelease.signal()
    }

    @Test func sessionManagerUsesInitializeParamsOverrideFromConfigFile() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "custom-proxy"

            [upstream_handshake.capabilities]
            roots = true
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        config.loadFileConfig()
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "custom-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
        #expect(capabilities["roots"] as? Bool == true)
    }

    @Test func sessionManagerAutoResolvesInitializeVersionFromConfiguredClientName() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "Claude"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        config.loadFileConfig()
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultClientVersion(for: "Claude"))
    }

    @Test func xcodeChatClientVersionFallsBackToCodeAliasWhenExactStemMissing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let version = InitializeHandshakeParams.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "9.9.9")
    }

    @Test func xcodeChatClientVersionPrefersExactStemMatchOverGenericCodeAlias() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let version = InitializeHandshakeParams.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeVersion": #"{"version":"1.2.3"}"#,
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "1.2.3")
    }

    @Test func sessionManagerFallsBackToDefaultInitializeParamsWhenConfigFileIsInvalid()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake
            protocolVersion = "broken"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        config.loadFileConfig()
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == InitializeHandshakeParams.defaultProxyClientName())
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
    }

    @Test func sessionManagerUsesConfiguredInitializeParamsAfterEagerInitTimesOut()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "configured-proxy"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutClock = TestClock()
        var config = makeConfig(requestTimeout: 0.1)
        config.configPath = configPath
        config.loadFileConfig()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock)
        )
        defer { manager.shutdownAndWait() }

        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for eager initialize request"
        )
        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .milliseconds(100))
        try await waitWithTimeout("waiting for eager initialize timeout") {
            while manager.testStateSnapshot().initInFlight {
                await Task.yield()
            }
        }

        _ = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2099-01-01",
                    "capabilities": [String: Any](),
                    "clientInfo": [
                        "name": "downstream-client",
                        "version": "9.9",
                    ],
                ],
            ],
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let resent = try #require(await upstream.sentValue(at: 1))
        let object = try JSONSerialization.jsonObject(with: resent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "configured-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
    }

    @Test func sessionManagerSendsInitializedOnce() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        _ = try await future.get()
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))

        let cached = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        let cachedResponse = try decodeJSON(from: try await cached.get())
        let cachedID = (cachedResponse["id"] as? NSNumber)?.intValue
        #expect(cachedID == 2)
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerSendsInitializedBeforeQueuedRequestAfterWarmInit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(queuedRequestData, upstreamIndex: selectedUpstreamIndex)
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        _ = try await queuedFuture.get()

        let initializedNotification = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        let queuedRequest = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(methodName(from: queuedRequest) == "tools/list")

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerPrimaryExitClearsCachedInitializeResult() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // First init establishes the cached init result.
        let init1 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID1 = try extractUpstreamID(from: firstInit)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID1)))
        _ = try await init1.get()

        // Wait for notifications/initialized.
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        // Simulate primary upstream dying after init succeeded.
        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for primary upstream exit"
        )
        #expect(manager.testStateSnapshot().hasInitResult == false)

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let upstreamID2 = try extractUpstreamID(from: (await upstream.sent())[2])
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerPrimaryEagerRetryClearsCanonicalToolsCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.setCachedToolsListResult(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        #expect(manager.cachedToolsListResult() != nil)

        manager.startPrimaryEagerRetry()

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerKeepsQueuedRequestsWaitingWhileReinitializeIsInFlight() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 199),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(queuedRequestData, upstreamIndex: selectedUpstreamIndex)
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        await upstream.yield(.exit(1))

        let reinitRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(manager.testStateSnapshot().upstreams[0].initInFlight)
        #expect(manager.debugSnapshot().queuedRequestCount == 1)
        let reinitUpstreamID = try extractUpstreamID(from: reinitRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: reinitUpstreamID)))
        _ = try await queuedFuture.get()

        let initializedNotification = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        let queuedRequest = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(methodName(from: queuedRequest) == "tools/list")

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerSecondaryExitClearsCachedInitializeResultWhenPrimaryAlreadyDown()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // First init establishes the cached init result (primary only).
        let init1 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let upstreamID0 = try extractUpstreamID(from: firstInit)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID0)))
        _ = try await init1.get()

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1Messages = await upstream1.sent()
        let upstreamID1 = try extractUpstreamID(from: init1Messages[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: upstreamID1)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        let primaryExitEventIndex = upstreamEvents.count()
        await upstream0.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: primaryExitEventIndex,
            description: "waiting for primary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstreams[0].isInitialized == false)

        // Now simulate the last initialized upstream dying too.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == false)

        // Ensure the cached init result is cleared before asserting that a new downstream initialize
        // triggers a fresh upstream initialize. This avoids race/flakiness where the exit event hasn't
        // been processed yet on the event loop.
        #expect(manager.testStateSnapshot().hasInitResult == false)

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
        let secondInitialize = (await upstream0.sent())[3]
        #expect(methodName(from: secondInitialize) == "initialize")
        let upstreamID2 = try extractUpstreamID(from: secondInitialize)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerEagerInitializeRerunsPrimaryInitWhenLastInitializedUpstreamExits()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(
            .message(try makeInitializeResponse(id: init0ID, serverName: "cached-handshake"))
        )

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(
            .message(try makeInitializeResponse(id: init1ID, serverName: "secondary-ready"))
        )

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        await upstream0.yield(.exit(1))

        // Primary warm init should be attempted, but we simulate it failing.
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        let errorEventIndex = upstreamEvents.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: errorEventIndex,
            description: "waiting for primary warm init failure"
        )
        #expect(manager.testStateSnapshot().upstreams[0].initInFlight == false)

        // Now simulate the last initialized upstream dying too. Eager init should kick the global init path again.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test
    func
        sessionManagerRetriesEagerInitializeAfterPrimaryWarmInitErrorWhenLastInitializedUpstreamExited()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        // Primary exit triggers warm init on primary.
        await upstream0.yield(.exit(1))
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)

        // While primary warm init is in flight, last initialized upstream exits.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == false)

        // Warm init fails with JSON-RPC error.
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))

        // Proxy should restart eager/global init automatically.
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test func sessionManagerPinsSessionsRoundRobinAcrossUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Eager init -> upstream0
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        let originalA = JSONRPC.ID(any: NSNumber(value: 100))!
        let originalB = JSONRPC.ID(any: NSNumber(value: 101))!

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex())
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexA != upstreamIndexB)

        let futureA = sessionA.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionIDA,
            originalID: originalA,
            upstreamIndex: upstreamIndexA
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDA), upstreamIndex: upstreamIndexA)

        let futureB = sessionB.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionIDB,
            originalID: originalB,
            upstreamIndex: upstreamIndexB
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)

        await yieldMessage(
            try makeToolListResponse(id: upstreamIDA),
            to: upstreamIndexA == 0 ? upstream0 : upstream1
        )
        await yieldMessage(
            try makeToolListResponse(id: upstreamIDB),
            to: upstreamIndexB == 0 ? upstream0 : upstream1
        )

        _ = try await futureA.get()
        _ = try await futureB.get()

        let methods0 = await upstream0.sent().compactMap(methodName(from:))
        let methods1 = await upstream1.sent().compactMap(methodName(from:))
        #expect(methods0.filter { $0 == "tools/list" }.count == 1)
        #expect(methods1.filter { $0 == "tools/list" }.count == 1)
    }

    @Test func sessionManagerDropsUnmappedNotificationsAfterInitializeRoutingEnds() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        // Ensure we're starting from a clean buffer state.
        _ = sessionA.router.drainBufferedNotifications()
        _ = sessionB.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(
            sessionA.router.drainBufferedNotifications().isEmpty
                && sessionB.router.drainBufferedNotifications().isEmpty
        )
    }

    @Test func sessionManagerDropsUnmappedNotificationsWhenNoPinnedTargetsExist()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Create a session, but do not pin it yet.
        let sessionID = "session-A"
        let session = manager.session(id: sessionID)

        // Ensure we're starting from a clean buffer state.
        _ = session.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDropsUnmappedResponsesEvenWhenPinnedTargetsExist() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = manager.chooseUpstreamIndex()

        _ = session.router.drainBufferedNotifications()

        // Unmapped JSON-RPC response (no `method`) must never be routed to sessions.
        manager.routeUpstreamMessage(try makeToolListResponse(id: 9_999_999), upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDebugSnapshotCapturesTrafficAndStderr() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initMessages = await upstream.sent()
        let initID = try extractUpstreamID(from: initMessages[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-debug"
        let session = manager.session(id: sessionID)
        let upstreamIndex = try #require(
            manager.chooseUpstreamIndex())
        let original = JSONRPC.ID(any: NSNumber(value: 301))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(1))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: original,
            upstreamIndex: upstreamIndex
        )
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: upstreamIndex)
        await upstream.yield(.message(try makeToolListResponse(id: upstreamID)))
        _ = try await future.get()

        let debugEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeToolListResponse(id: 9_999_999)))
        await upstream.yield(
            .stderr("Could not decode agent message: Error Domain=mcpbridge.DecodeError Code=1"))
        await upstream.yield(
            .stderr(
                "callTool request for 'DocumentationSearch' failed: Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"
            ))
        await upstream.yield(
            .stdoutProtocolViolation(
                StdioFramer.ProtocolViolation(
                    reason: .invalidJSON,
                    bufferedByteCount: 1024,
                    preview: "...broken"
                )
            )
        )
        await upstream.yield(.stdoutBufferSize(2048))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: debugEventIndex + 4,
            description: "waiting for upstream debug events"
        )

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams.count == 1)
        #expect(snapshot.upstreams[0].lastDecodeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].lastBridgeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].protocolViolationCount == 1)
        #expect(snapshot.upstreams[0].lastProtocolViolationReason == "invalidJSON")
        #expect(snapshot.upstreams[0].lastProtocolViolationBufferedBytes == 1024)
        #expect(snapshot.upstreams[0].lastProtocolViolationPreview == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationPreviewHex == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(snapshot.upstreams[0].bufferedStdoutBytes == 2048)
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" && $0.bytes > 0 })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound" && $0.preview == "<redacted>"
            })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound_unmapped" && $0.preview == "<redacted>"
            })
        #expect(snapshot.upstreams[0].recentStderr.allSatisfy { $0.message == "<redacted>" })

        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for upstream exit debug reset"
        )

        let clearedSnapshot = manager.debugSnapshot()
        #expect(clearedSnapshot.upstreams[0].recentStderr.isEmpty)
        #expect(clearedSnapshot.upstreams[0].lastDecodeError == nil)
        #expect(clearedSnapshot.upstreams[0].lastBridgeError == nil)
        #expect(clearedSnapshot.upstreams[0].protocolViolationCount == 0)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreview == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreviewHex == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(clearedSnapshot.upstreams[0].bufferedStdoutBytes == 0)
    }

    @Test func sessionManagerReturnsNilWhenAllUpstreamsAreQuarantined() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        var config = makeConfig(requestTimeout: 2)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                toolsListRefreshCompleted: { toolsListRefreshes.append(($0, $1)) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize primary upstream0.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1.
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Fail tools/list warmup on upstream0 to mark it unhealthy.
        manager.refreshToolsListIfNeeded()
        let warmup0 = try await sentMessage(
            from: upstream0,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup0ID = try extractUpstreamID(from: warmup0)
        let warmup0Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup0ID,
            "result": [:],  // invalid (no `tools` array) -> marks upstream unhealthy
        ]
        let warmup0RefreshIndex = toolsListRefreshes.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup0Response, options: [])))
        _ = try await waitForRecordedValue(
            toolsListRefreshes,
            at: warmup0RefreshIndex,
            description: "waiting for first tools/list warmup failure"
        )
        switch manager.testStateSnapshot().upstreams[0].healthState {
        case .healthy:
            Issue.record("upstream0 should be degraded after invalid tools/list warmup")
        case .degraded, .quarantined:
            break
        }

        // Trigger another warmup; it should prefer upstream1 and fail there too so no healthy upstream exists.
        manager.refreshToolsListIfNeeded()
        let warmup1 = try await sentMessage(
            from: upstream1,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup1ID = try extractUpstreamID(from: warmup1)
        let warmup1Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup1ID,
            "result": [:],
        ]
        let warmup1RefreshIndex = toolsListRefreshes.count()
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup1Response, options: [])))
        _ = try await waitForRecordedValue(
            toolsListRefreshes,
            at: warmup1RefreshIndex,
            description: "waiting for second tools/list warmup failure"
        )

        let chosen = manager.chooseUpstreamIndex()
        #expect(chosen == nil)
    }

    @Test func sessionManagerEnqueueOnUpstreamSlotStartsRecoveryProbeWhenAllUpstreamsAreQuarantined() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: { uptimeClock.now() }
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for eager initialize request"
        )
        let initRequest = try #require(await upstream.sentValue(at: 0))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await spinUntilSentCount(
            upstream,
            count: 2,
            description: "waiting for initialized notification"
        )

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-quarantine-recovery",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await future.get()
        }

        try await spinUntilSentCount(
            upstream,
            count: 3,
            description: "waiting for recovery probe request"
        )
        let probe = try #require(await upstream.sentValue(at: 2))
        #expect(methodName(from: probe) == "tools/list")
    }

    @Test func sessionManagerQueuedRequestStartsProbeForExpiredQuarantinedUpstream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            nowUptimeNanoseconds: { uptimeClock.now() }
        )
        defer { manager.shutdownAndWait() }

        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        guard case .quarantined = manager.testStateSnapshot().upstreams[1].healthState else {
            Issue.record("expected upstream1 to be quarantined before queueing request")
            return
        }

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(queuedRequestData, upstreamIndex: selectedUpstreamIndex)
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        try await spinUntilSentCount(
            upstream1,
            count: 1,
            description: "waiting for recovery probe request"
        )
        let probeRequest = try #require(await upstream1.sentValue(at: 0))
        #expect(methodName(from: probeRequest) == "tools/list")
        let probeID = try extractUpstreamID(from: probeRequest)
        #expect(probeID != 99)
        let probeResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: probeID),
            "result": [
                "tools": [Any]()
            ],
        ]
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: probeResponse, options: []))
        )

        _ = try await queuedFuture.get()
        try await spinUntilSentCount(
            upstream1,
            count: 2,
            description: "waiting for queued request dispatch after probe recovery"
        )
        let queuedRequest = try #require(await upstream1.sentValue(at: 1))
        #expect(methodName(from: queuedRequest) == "tools/list")
        #expect(try extractUpstreamID(from: queuedRequest) == 99)

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerQueuedPreferredRequestDoesNotBlockLaterGenericDispatch()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            #expect(selectedUpstreamIndex == 0)
            return activePromise.futureResult
        }
        _ = activeFuture

        let preferredDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-preferred",
            label: "tools/call:XcodeListWindows",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let preferredLeaseID = manager.createRequestLease(descriptor: preferredDescriptor)
        let preferredStartedUpstream = NIOLockedValueBox<Int?>(nil)
        let preferredFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: preferredLeaseID,
            descriptor: preferredDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedUpstreamIndex in
            preferredStartedUpstream.withLockedValue { $0 = selectedUpstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        let genericDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-generic",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let genericLeaseID = manager.createRequestLease(descriptor: genericDescriptor)
        let genericStartedUpstream = NIOLockedValueBox<Int?>(nil)
        let genericFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: genericLeaseID,
            descriptor: genericDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            genericStartedUpstream.withLockedValue { $0 = selectedUpstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        _ = try await genericFuture.get()
        #expect(genericStartedUpstream.withLockedValue { $0 } == 1)
        #expect(preferredStartedUpstream.withLockedValue { $0 } == nil)
        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.completeRequestLease(activeLeaseID)
        activePromise.succeed(())
        _ = try await preferredFuture.get()
        #expect(preferredStartedUpstream.withLockedValue { $0 } == 0)
    }

    @Test func sessionManagerPreferredRequestFailsWhenAllPreferredUpstreamsUnusable()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            nowUptimeNanoseconds: { uptimeClock.now() },
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        _ = manager.upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )
        _ = manager.upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )
        _ = manager.upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-preferred-unusable",
            label: "tools/call:BuildProject",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let startedUpstream = NIOLockedValueBox<Int?>(nil)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndices: [0]
        ) { selectedUpstreamIndex in
            startedUpstream.withLockedValue { $0 = selectedUpstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await future.get()
        }
        #expect(startedUpstream.withLockedValue { $0 } == nil)
        #expect(manager.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func sessionManagerRepinsAfterUpstreamExit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Pin two sessions to different upstreams.
        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        _ = manager.session(id: sessionIDA)
        _ = manager.session(id: sessionIDB)

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex())
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexA != upstreamIndexB)

        let exitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == false)

        let repinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(repinned == 0)
    }

    @Test func sessionManagerRepinsWhenPinnedUpstreamIsQuarantinedByTimeouts() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-timeout-repin"
        _ = manager.session(id: sessionID)
        let pinned = try #require(
            manager.chooseUpstreamIndex())

        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-1", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-2", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-3", upstreamIndex: pinned)

        let repinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(repinned != pinned)
    }

    @Test func sessionManagerExitClearsMappingsAndKeepsServingOnOtherUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        await upstream0.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init0[0]))))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        await upstream1.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init1[0]))))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-1"
        let session = manager.session(id: sessionID)

        // Send a request to upstream1, then kill upstream1 before it can respond.
        let originalA = JSONRPC.ID(any: NSNumber(value: 200))!
        let futureA = session.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalA, upstreamIndex: 1)
        manager.sendUpstream(try makeToolListRequest(id: upstreamIDA), upstreamIndex: 1)

        let exitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == false)

        // The proxy should continue serving on upstream0.
        let originalB = JSONRPC.ID(any: NSNumber(value: 201))!
        let futureB = session.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexB == 0)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalB, upstreamIndex: upstreamIndexB)
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)
        await upstream0.yield(.message(try makeToolListResponse(id: upstreamIDB)))
        _ = try await futureB.get()

        // A should time out (mapping is cleared on exit, and no response arrives).
        do {
            _ = try await waitWithTimeout(
                "request routed to exited upstream should fail with TimeoutError",
                timeout: .seconds(2)
            ) {
                try await futureA.get()
            }
            #expect(Bool(false))
        } catch {
            #expect(error is TimeoutError)
        }
    }

    @Test func sessionManagerReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-overloaded"
        let session = manager.session(id: sessionID)
        let original = JSONRPC.ID(any: NSNumber(value: 910))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original, upstreamIndex: 0)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: 0)

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "overloaded upstream should fail request immediately",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" } == false)
    }

    @Test func sessionManagerInitializeReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let original = JSONRPC.ID(any: NSNumber(value: 1001))!
        let future = manager.registerInitialize(
            originalID: original,
            requestObject: makeInitializeRequest(id: 1001),
            on: eventLoop
        )

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "initialize should surface overloaded upstream error",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")
    }

    @Test func sessionManagerRepinsWhenPinnedUpstreamBecomesOverloaded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-overload-repin"
        let session = manager.session(id: sessionID)
        let pinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(pinned == 0)

        await upstream0.setOverloaded(true)

        let original = JSONRPC.ID(any: NSNumber(value: 920))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original, upstreamIndex: pinned)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: pinned)

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "overloaded pinned upstream should fail request immediately",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")

        let repinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(repinned == 1)

        let original2 = JSONRPC.ID(any: NSNumber(value: 921))!
        let future2 = session.router.registerRequest(
            idKey: original2.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID2 = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original2, upstreamIndex: repinned)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID2), upstreamIndex: repinned)
        await upstream1.yield(.message(try makeToolListResponse(id: upstreamID2)))
        _ = try await waitWithTimeout(
            "repinned upstream should return response",
            timeout: .seconds(2)
        ) {
            try await future2.get()
        }
    }

    @Test func sessionManagerRetriesPrimaryInitializeWhenInitializedNotificationSendOverloads()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initialInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)
        await upstream.overloadNextInitializedNotificationSend()
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: retriedInitialize) == "initialize")
        #expect(manager.testStateSnapshot().hasInitResult == false)
    }

    @Test func sessionManagerPrimaryInitializedNotificationOverloadClearsSecondaryStateAndToolsCache()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let cachedToolsList = try #require(JSONValue(any: ["tools": []]))
        manager.setCachedToolsListResult(cachedToolsList, sourceUpstream: 0)

        let initialInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)
        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == false)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadKeepsHealthySecondaryAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let cachedToolsList = try #require(JSONValue(any: ["tools": []]))
        manager.setCachedToolsListResult(cachedToolsList, sourceUpstream: 0)

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        await upstream0.yield(.exit(1))
        let warmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmRetryID = try extractUpstreamID(from: warmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: warmRetryID)))

        try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
        let overloadedInitialized = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        #expect(methodName(from: overloadedInitialized) == "notifications/initialized")
        #expect(manager.cachedToolsListResult() != nil)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized)
        let chosen = manager.chooseUpstreamIndex()
        #expect(chosen == 1)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadReturnsPendingInitializeUsingHealthySecondary()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        await upstream0.yield(.exit(1))
        let warmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmRetryID = try extractUpstreamID(from: warmRetry)

        manager.canonicalBrokerState.clearInitialize()
        manager.initializeManager.resetWarmSecondaryForRetry()
        let cachedHandshake = try #require(JSONValue(any: [
            "capabilities": [String: Any](),
            "serverInfo": ["name": "cached-handshake"],
        ]))
        manager.canonicalBrokerState.syncCanonicalInitialize(cachedHandshake, sourceUpstream: 0)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 77))!,
            requestObject: makeInitializeRequest(id: 77),
            on: eventLoop
        )

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(
            .message(try makeInitializeResponse(id: warmRetryID, serverName: "primary-retry"))
        )

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "healthy secondary should satisfy pending initialize during primary warm retry",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        #expect(response["result"] != nil)
        let result = try #require(response["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "cached-handshake")

        let secondWarmRetry = try await waitWithTimeout(
            "primary should start another warm initialize after overload",
            timeout: .seconds(2)
        ) {
            try await upstream0.nextSent(
                startingAt: 3,
                matching: { methodName(from: $0) == "initialize" }
            )
        }
        #expect(methodName(from: secondWarmRetry) == "initialize")
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadResetsCacheWhenSecondaryIsQuarantined()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let cachedToolsList = try #require(JSONValue(any: ["tools": []]))
        manager.setCachedToolsListResult(cachedToolsList, sourceUpstream: 0)

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        guard case .quarantined = manager.testStateSnapshot().upstreams[1].healthState else {
            Issue.record("expected upstream1 to be quarantined")
            return
        }

        await upstream0.yield(.exit(1))
        let warmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmRetryID = try extractUpstreamID(from: warmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: warmRetryID)))

        try await waitForSentCount(upstream0, count: 5, timeoutSeconds: 2)
        let eagerRetry = try await sentValue(from: upstream0, at: 4, timeout: .seconds(2))
        #expect(methodName(from: eagerRetry) == "initialize")
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.testStateSnapshot().upstreams[1].isInitialized == false)
    }

    @Test func sessionManagerIgnoresStaleSecondaryInitializedNotificationAfterReset()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = BlockingInitializedNotificationUpstreamClient()
        let staleInitializedIgnored = TestSignal()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                initializedNotificationStaleIgnored: { upstreamIndex in
                    if upstreamIndex == 1 {
                        staleInitializedIgnored.signal()
                    }
                }
            )
        )
        defer { manager.shutdownAndWait() }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream1.blockNextInitializedNotification()
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await upstream1.waitForBlockedInitializedNotification()

        #expect(manager.testStateSnapshot().upstreams[1].initInFlight)
        manager.clearUpstreamState(upstreamIndex: 1)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        await upstream1.releaseBlockedInitializedNotification(.accepted)
        try await staleInitializedIgnored.wait(
            description: "stale initialized notification completion should be ignored"
        )

        let snapshot = manager.testStateSnapshot().upstreams[1]
        #expect(snapshot.isInitialized == false)
        guard case .quarantined = snapshot.healthState else {
            Issue.record("expected upstream to remain quarantined")
            return
        }
    }

    @Test func sessionManagerShutdownStopsUpstreamsBeforeDrainingRuntimeTasks() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = BlockingInitializedNotificationUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )

        var didShutdown = false
        defer {
            if !didShutdown {
                manager.shutdownAndWait()
            }
        }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream1.blockNextInitializedNotification()
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await upstream1.waitForBlockedInitializedNotification()

        let shutdownFinished = TestSignal()
        let shutdownTask = Task {
            await manager.shutdown()
            shutdownFinished.signal()
        }

        do {
            try await shutdownFinished.wait(
                timeout: .milliseconds(500),
                description: "shutdown should stop upstreams before draining blocked runtime tasks"
            )
        } catch {
            await upstream1.releaseBlockedInitializedNotification(.backpressure)
            await shutdownTask.value
            throw error
        }
        await shutdownTask.value
        didShutdown = true
    }

    @Test func upstreamHealthManagerIgnoresStaleInitializeCompletionAfterStateReset() {
        let manager = UpstreamHealthManager(upstreamCount: 1)
        manager.markInitInFlight(upstreamIndex: 0, upstreamID: 10)
        guard let _ = manager.clearUpstreamState(upstreamIndex: 0) else {
            Issue.record("expected initial reset to clear the active initialize attempt")
            return
        }

        if let _ = manager.markInitialized(upstreamIndex: 0, expectedUpstreamID: 10) {
            Issue.record("expected stale initialize completion to be ignored")
        }
        if let _ = manager.clearUpstreamState(upstreamIndex: 0, expectedUpstreamID: 10) {
            Issue.record("expected stale initialized notification rejection to be ignored")
        }
        let snapshot = manager.statesSnapshot()[0]
        #expect(snapshot.isInitialized == false)
        #expect(snapshot.initInFlight == false)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadFallsBackToEagerInitAfterWarmRetryFailure()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        await upstream0.yield(.exit(1))
        let firstWarmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let firstWarmRetryID = try extractUpstreamID(from: firstWarmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: firstWarmRetryID)))

        try await waitForSentCount(upstream0, count: 5, timeoutSeconds: 2)
        let secondWarmRetry = try await sentValue(from: upstream0, at: 4, timeout: .seconds(2))
        let secondWarmRetryID = try extractUpstreamID(from: secondWarmRetry)

        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: secondWarmRetryID),
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        let errorEventIndex = upstreamEvents.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: errorEventIndex,
            description: "waiting for warm init failure"
        )

        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.shouldRetryEagerInitializePrimaryAfterWarmInitFailure)
        #expect(snapshot.upstreams[0].isInitialized == false)
        #expect(snapshot.upstreams[0].initInFlight == false)

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-recovery-trigger",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }
        defer {
            manager.abandonRequestLease(
                leaseID,
                sessionID: "session-recovery-trigger",
                requestIDKeys: [],
                upstreamIndex: nil
            )
        }
        _ = future

        try await waitForSentCount(upstream0, count: 6, timeoutSeconds: 5)
        let eagerRetry = try await sentValue(from: upstream0, at: 5, timeout: .seconds(2))
        #expect(methodName(from: eagerRetry) == "initialize")

        manager.abandonRequestLease(
            leaseID,
            sessionID: "session-recovery-trigger",
            requestIDKeys: [],
            upstreamIndex: nil
        )
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
    }

    @Test func sessionManagerAbandonQueuedRequestFailsPendingFuture() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.abandonRequestLease(
            queuedLeaseID,
            sessionID: "session-queued",
            requestIDKeys: [],
            upstreamIndex: nil
        )

        await #expect(throws: CancellationError.self) {
            try await queuedFuture.get()
        }

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerAbandonRequestLeaseDropsLateResponseAndReleasesSlot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-disconnect"
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        manager.activateRequestLease(
            leaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        manager.abandonRequestLease(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: [originalID.key],
            upstreamIndex: 0
        )

        let releaseSnapshot = manager.debugSnapshot()
        let releasedLease = try #require(
            releaseSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(releasedLease.releaseReason == "clientDisconnected")
        #expect(releaseSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
            "result": [String: Any](),
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: response, options: []),
            upstreamIndex: 0
        )

        let lateSnapshot = manager.debugSnapshot()
        let lateLease = try #require(
            lateSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(lateLease.releaseReason == "clientDisconnected")
    }

    @Test func sessionManagerDoesNotReactivateAbandonedLease() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let leaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: "session-terminal-lease",
                label: "tools/call:DocumentationSearch",
                isBatch: false,
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )

        manager.abandonRequestLease(
            leaseID,
            sessionID: "session-terminal-lease",
            requestIDKeys: [],
            upstreamIndex: nil
        )
        manager.activateRequestLease(
            leaseID,
            requestIDKey: "reactivated",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )

        let snapshot = manager.debugSnapshot()
        let lease = try #require(
            snapshot.leases.first(where: { $0.leaseID == leaseID.uuidString })
        )
        #expect(lease.state == .abandoned)
        #expect(lease.releaseReason == "clientDisconnected")
        #expect(snapshot.upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerProtocolViolationReleasesActiveLeaseAndAllowsNextRequest() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-protocol-violation"
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 41)))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        manager.activateRequestLease(
            leaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        let releaseSnapshot = manager.debugSnapshot()
        let releasedLease = try #require(
            releaseSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(releasedLease.releaseReason == "stdoutProtocolViolation")
        #expect(releaseSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
            "result": [String: Any](),
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: response, options: []),
            upstreamIndex: 0
        )

        let lateSnapshot = manager.debugSnapshot()
        let lateLease = try #require(
            lateSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(lateLease.releaseReason == "stdoutProtocolViolation")

        let nextLeaseID = manager.createRequestLease(descriptor: descriptor)
        let nextOriginalID = try #require(JSONRPC.ID(any: NSNumber(value: 42)))
        let nextUpstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: nextOriginalID,
            upstreamIndex: 0
        )
        manager.activateRequestLease(
            nextLeaseID,
            requestIDKey: nextOriginalID.key,
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        _ = nextUpstreamID
        manager.completeRequestLease(nextLeaseID)

        let successSnapshot = manager.debugSnapshot()
        let nextLease = try #require(
            successSnapshot.leases.first(where: { $0.requestIDKey == nextOriginalID.key })
        )
        #expect(nextLease.releaseReason == "completed")
        #expect(successSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerProtocolViolationQuarantinesBrokenUpstream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        let snapshot = manager.testStateSnapshot()
        let isQuarantined: Bool
        if case .quarantined = snapshot.upstreams[0].healthState {
            isQuarantined = true
        } else {
            isQuarantined = false
        }
        #expect(isQuarantined)
        #expect(manager.chooseUpstreamIndex() == nil)
    }

    @Test func sessionManagerUpstreamExitClearsCanonicalToolsCatalogImmediately() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.setCachedToolsListResult(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        #expect(manager.cachedToolsListResult() != nil)

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerProtocolViolationClearsCanonicalToolsCatalogImmediately()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.setCachedToolsListResult(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        #expect(manager.cachedToolsListResult() != nil)

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 64,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerProtocolViolationRestartsWarmInitializeForPrimary() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)

        let restartedInitRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let object = try #require(
            JSONSerialization.jsonObject(with: restartedInitRequest, options: []) as? [String: Any]
        )
        #expect(object["method"] as? String == "initialize")
    }

    @Test func sessionManagerProtocolViolationFailsQueuedRequestsWhenNoHealthyUpstreamRemains() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await queuedFuture.get()
        }
        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerFailsQueuedRequestsWhenHealthProbeRecoveryFails() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.chooseUpstreamIndex()

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-probe-failure",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        let probeRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let probeUpstreamID = try extractUpstreamID(from: probeRequest)
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: probeUpstreamID),
            "error": [
                "code": NSNumber(value: -32000),
                "message": "probe failed",
            ],
        ]
        await upstream.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await queuedFuture.get()
        }
    }

    @Test func sessionManagerTimeoutQuarantineFailsQueuedRequestsWhenNoHealthyUpstreamRemains()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-timeout-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: "active-request",
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-timeout-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.onRequestTimeout(
            sessionID: activeDescriptor.sessionID,
            requestIDKey: "timeout-1",
            upstreamIndex: 0
        )
        manager.onRequestTimeout(
            sessionID: activeDescriptor.sessionID,
            requestIDKey: "timeout-2",
            upstreamIndex: 0
        )
        manager.handleRequestLeaseTimeout(
            activeLeaseID,
            sessionID: activeDescriptor.sessionID,
            requestIDKeys: ["active-request"],
            upstreamIndex: 0
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await queuedFuture.get()
        }
        #expect(manager.debugSnapshot().queuedRequestCount == 0)

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerDebugResetClearsSessionsLeasesAndCache() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: group.next(), upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        _ = manager.session(id: "session-debug-reset")
        manager.setCachedToolsListResult(.object(["tools": .array([])]), sourceUpstream: 0)

        let leaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: "session-debug-reset",
                label: "tools/call:DocumentationSearch",
                isBatch: false,
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            leaseID,
            requestIDKey: "123",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )

        manager.debugReset()

        #expect(manager.hasSession(id: "session-debug-reset") == false)
        let snapshot = manager.debugSnapshot()
        #expect(snapshot.cachedToolsListAvailable == false)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.leases.isEmpty)
    }

    @Test func sessionManagerDebugResetClearsXcodeWindowOwners() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 522, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        let request = toolsCallObject(
            id: 1000,
            name: "BuildProject",
            arguments: ["tabIdentifier": "tab-a"]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 0)

        manager.debugReset()

        #expect(manager.preferredUpstreamIndex(for: request) == nil)
    }

    @Test func sessionManagerDebugResetCancelsQueuedRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.debugReset()

        await #expect(throws: CancellationError.self) {
            try await queuedFuture.get()
        }

        activePromise.fail(CancellationError())
    }

    @Test func requestLeaseRegistryKeepsOnlyBoundedReleasedHistory() async throws {
        let registry = LeaseManager(releasedHistoryLimit: 2)
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-bounded-history",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )

        let lease1 = registry.createLease(descriptor: descriptor)
        registry.activateLease(lease1, requestIDKey: "1", upstreamIndex: 0, timeoutAt: nil)
        _ = registry.completeLease(lease1)

        let lease2 = registry.createLease(descriptor: descriptor)
        registry.activateLease(lease2, requestIDKey: "2", upstreamIndex: 0, timeoutAt: nil)
        _ = registry.failLease(lease2, terminalState: .failed, reason: .upstreamUnavailable)

        let lease3 = registry.createLease(descriptor: descriptor)
        registry.activateLease(lease3, requestIDKey: "3", upstreamIndex: 0, timeoutAt: nil)
        _ = registry.completeLease(lease3)
        _ = registry.completeLease(lease3)

        let snapshots = registry.debugSnapshots()
        #expect(snapshots.count == 2)
        #expect(Set(snapshots.map(\.leaseID)) == Set([lease2.uuidString, lease3.uuidString]))
        let latest = try #require(snapshots.first { $0.leaseID == lease3.uuidString })
        #expect(latest.lateResponseCount == 1)
    }

    @Test func requestLeaseRegistryRequeueLeaseReleasesActiveSlotAndKeepsLeaseQueued()
        async throws
    {
        let registry = LeaseManager()
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-requeue",
            label: "tools/call:XcodeRefreshCodeIssuesInFile",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )

        let lease = registry.createLease(descriptor: descriptor)
        registry.activateLease(
            lease,
            requestIDKey: "refresh-1",
            upstreamIndex: 0,
            timeoutAt: Date().addingTimeInterval(30)
        )

        let releaseAction = try #require(registry.requeueLease(lease))
        #expect(releaseAction.leaseID == lease)
        #expect(releaseAction.upstreamIndex == 0)

        let snapshot = try #require(registry.debugSnapshots().first { $0.leaseID == lease.uuidString })
        #expect(snapshot.state == .queued)
        #expect(snapshot.requestIDKey == nil)
        #expect(snapshot.upstreamIndex == nil)
        #expect(snapshot.timeoutAt == nil)
        #expect(snapshot.releaseReason == nil)
    }

    @Test func requestLeaseRegistryAbandonActiveLeasesUsesBoundedReleasedHistory()
        async throws
    {
        let registry = LeaseManager(releasedHistoryLimit: 1)
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-abandon-history",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )

        let abandonedLease = registry.createLease(descriptor: descriptor)
        registry.activateLease(
            abandonedLease,
            requestIDKey: "abandon-1",
            upstreamIndex: 0,
            timeoutAt: nil
        )
        let abandonActions = registry.abandonActiveLeases(
            upstreamIndex: 0,
            reason: .stdoutProtocolViolation
        )
        #expect(abandonActions.count == 1)

        let completedLease = registry.createLease(descriptor: descriptor)
        registry.activateLease(
            completedLease,
            requestIDKey: "complete-1",
            upstreamIndex: 1,
            timeoutAt: nil
        )
        _ = registry.completeLease(completedLease)

        let snapshots = registry.debugSnapshots()
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.leaseID == completedLease.uuidString)
        #expect(snapshot.state == .completed)
    }

    @Test func upstreamSlotSchedulerCancelsReservedDispatchBeforeStartWithoutLeakingSlot()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 1)
        let startedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])
        let cancelledLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])

        let firstDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-race-1",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let firstLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: firstLeaseID,
            descriptor: firstDescriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(firstLeaseID) }
            },
            failUnavailable: {
                Issue.record("first request should be cancelled, not failed unavailable")
            },
            failCancelled: {
                cancelledLeaseIDs.withLockedValue { $0.append(firstLeaseID) }
            }
        )

        scheduler.cancelQueuedRequest(leaseID: firstLeaseID)

        let secondDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-race-2",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let secondLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: secondLeaseID,
            descriptor: secondDescriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(secondLeaseID) }
            },
            failUnavailable: {
                Issue.record("second request should start after the cancelled reservation releases")
            },
            failCancelled: {
                Issue.record("second request should not be cancelled")
            }
        )

        eventLoop.run()

        #expect(cancelledLeaseIDs.withLockedValue { $0 } == [firstLeaseID])
        #expect(startedLeaseIDs.withLockedValue { $0 } == [secondLeaseID])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func upstreamSlotSchedulerFailsReservedDispatchBeforeStartWhenQueueFails()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 1)
        let startedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])
        let failedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-fail-race",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(leaseID) }
            },
            failUnavailable: {
                failedLeaseIDs.withLockedValue { $0.append(leaseID) }
            },
            failCancelled: {
                Issue.record("reserved request should fail unavailable when queue is drained")
            }
        )

        scheduler.failQueuedRequests()
        eventLoop.run()

        #expect(failedLeaseIDs.withLockedValue { $0 } == [leaseID])
        #expect(startedLeaseIDs.withLockedValue { $0 }.isEmpty)
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func upstreamSlotSchedulerCancelsReservedDispatchBeforeStartWhenResetting()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 1)
        let startedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])
        let cancelledLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-reset-race",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(leaseID) }
            },
            failUnavailable: {
                Issue.record("reserved request should be cancelled during reset")
            },
            failCancelled: {
                cancelledLeaseIDs.withLockedValue { $0.append(leaseID) }
            }
        )

        scheduler.reset()
        eventLoop.run()

        #expect(cancelledLeaseIDs.withLockedValue { $0 } == [leaseID])
        #expect(startedLeaseIDs.withLockedValue { $0 }.isEmpty)
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func upstreamSlotSchedulerSerializesTopLevelRequestsPerSessionAcrossUpstreams()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 2)
        let started = NIOLockedValueBox<[String]>([])

        let firstDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-a",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let firstLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: firstLeaseID,
            descriptor: firstDescriptor,
            on: eventLoop,
            starter: { upstreamIndex in
                started.withLockedValue { $0.append("first@\(upstreamIndex)") }
            },
            failUnavailable: {
                Issue.record("first request should start")
            },
            failCancelled: {
                Issue.record("first request should not be cancelled")
            }
        )
        eventLoop.run()

        let secondDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-a",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let secondLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: secondLeaseID,
            descriptor: secondDescriptor,
            on: eventLoop,
            starter: { upstreamIndex in
                started.withLockedValue { $0.append("second@\(upstreamIndex)") }
            },
            failUnavailable: {
                Issue.record("second request should wait for the session slot, not fail unavailable")
            },
            failCancelled: {
                Issue.record("second request should not be cancelled")
            }
        )

        let thirdDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-b",
            label: "tools/call:XcodeListWindows",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let thirdLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: thirdLeaseID,
            descriptor: thirdDescriptor,
            on: eventLoop,
            starter: { upstreamIndex in
                started.withLockedValue { $0.append("third@\(upstreamIndex)") }
            },
            failUnavailable: {
                Issue.record("third request should use the other upstream")
            },
            failCancelled: {
                Issue.record("third request should not be cancelled")
            }
        )
        eventLoop.run()

        #expect(started.withLockedValue { $0 } == ["first@0", "third@1"])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 1)

        scheduler.releaseUpstreamSlot(upstreamIndex: 0, leaseID: firstLeaseID)
        eventLoop.run()

        #expect(started.withLockedValue { $0 } == ["first@0", "third@1", "second@0"])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

}
