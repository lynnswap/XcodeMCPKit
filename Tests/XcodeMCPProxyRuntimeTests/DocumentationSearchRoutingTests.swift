import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport


extension HTTPHandlerTests {
    @Test func httpDocumentationSearchFallsThroughWhenNoDocumentationProviderExists() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "DocumentationSearch")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-docs-fallthrough",
                payload: toolsCallPayload(
                    id: 62,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")
            #expect(sessionManager.sentToolNames() == ["DocumentationSearch"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDocumentationSearchRoutesThroughInactiveDocumentationProvider() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { _, _, originalID in
                Issue.record("DocumentationSearch should not be forwarded upstream")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cold-docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-docs-inactive-local",
                payload: toolsCallPayload(
                    id: 65,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "cold-docs")
            #expect(sessionManager.sentToolNames() == [])
            #expect(documentationRequests.withLockedValue { $0 } == ["hello"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDocumentationSearchReturnsUnavailableWhenProviderIsUnavailable() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { _, _, originalID in
                Issue.record("DocumentationSearch should not be forwarded upstream")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotScheduler.AcquisitionError.unavailable
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-docs-inactive-unavailable",
                payload: toolsCallPayload(
                    id: 66,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let error = try #require(body["error"] as? [String: Any])
            #expect((error["code"] as? NSNumber)?.intValue == -32001)
            #expect(error["message"] as? String == DocumentationProvider.UnavailableReason.userFacingMessage)
            #expect(sessionManager.sentToolNames() == [])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchFallsThroughWhenNoDocumentationProviderExists() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: toolName == "DocumentationSearch"
                            ? "{\"answer\":\"upstream-docs\"}"
                            : "other-tool-result"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-docs-batch-fallthrough",
                payload: [
                    toolsCallPayload(
                        id: 63,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "hello",
                        ]
                    ),
                    toolsCallPayload(
                        id: 64,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchRoutesDocumentationSearchThroughProviderAndForwardsOtherCalls() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-docs-batch",
                payload: [
                    toolsCallPayload(
                        id: 701,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView animate",
                        ]
                    ),
                    toolsCallPayload(
                        id: 702,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(documentationRequests.withLockedValue { $0 }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchForwardsDocumentationSearchNotificationWithProvider() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-docs-batch-notification",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "DocumentationSearch",
                            "arguments": [
                                "query": "UIView notification",
                            ],
                        ],
                    ],
                    toolsCallPayload(
                        id: 703,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(documentationRequests.withLockedValue { $0 }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchForwardsOtherCallsWhileDocumentationSearchIsStillResolving() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let documentationStarted = TestSignal()
        let releaseDocumentation = AsyncGate()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                documentationStarted.signal()
                try await releaseDocumentation.wait()
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let rawResponse = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-docs-batch-forwarding-not-blocked",
                payload: [
                    toolsCallPayload(
                        id: 721,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView animate",
                        ]
                    ),
                    toolsCallPayload(
                        id: 722,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(rawResponse.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            await releaseDocumentation.signal()
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchToolsListUsesLocalToolSurfaceAndForwardsOtherCalls() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "DocumentationSearch",
                        "description": "docs provider",
                    ],
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])!,
            sourceUpstream: 0
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-tools-list-batch-local",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 731,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 732,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentMethods().isEmpty)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchRoutesDocumentationSearchAfterSameBatchToolsListActivatesProvider() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "DocumentationSearch",
                        "description": "docs provider",
                    ],
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])!,
            sourceUpstream: 0
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-tools-list-activates-docs-route",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 741,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 742,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView same batch",
                        ]
                    ),
                    toolsCallPayload(
                        id: 743,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(documentationRequests.withLockedValue { $0 }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchReturnsUnavailableWhenSameBatchToolsListDoesNotActivateProvider()
        async throws
    {
        let config = makeHTTPConfig(requestTimeout: 2)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { _, _, originalID in
                Issue.record("DocumentationSearch should not be forwarded upstream")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotScheduler.AcquisitionError.unavailable
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])!,
            sourceUpstream: 0
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-tools-list-docs-unavailable",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 751,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 752,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView same batch unavailable",
                        ]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames() == [])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchReturnsDocumentationUnavailableBeforeOtherForwardedRequestTimesOut()
        async throws
    {
        let config = makeHTTPConfig(requestTimeout: 0.25)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                if toolName == "DocumentationSearch" {
                    Issue.record("DocumentationSearch should not be forwarded upstream")
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "{\"answer\":\"upstream-docs\"}"
                        )
                    )
                }
                #expect(toolName == "OtherAllowedTool")
                return .manual(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotScheduler.AcquisitionError.unavailable
            }
        )
        sessionManager.setAvailableUpstreamIndices([0, 1])
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-docs-unavailable-before-other-timeout",
                payload: [
                    toolsCallPayload(
                        id: 761,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView unavailable before timeout",
                        ]
                    ),
                    toolsCallPayload(
                        id: 762,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolRequests().isEmpty)
            #expect(localDocumentationRequests.withLockedValue { $0 } == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchSharesSingleDeadline() async throws {
        let config = makeHTTPConfig(requestTimeout: 0.1)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                let query = arguments["query"] as? String ?? ""
                documentationRequests.withLockedValue { requests in
                    requests.append(query)
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"\(query)\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-docs-batch-deadline",
                payload: [
                    toolsCallPayload(
                        id: 711,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "first",
                        ]
                    ),
                    toolsCallPayload(
                        id: 712,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "second",
                        ]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(documentationRequests.withLockedValue { $0 }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpSingleDocumentationSearchCancellationAbandonsPrefilterLease() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let documentationStarted = TestSignal()
        let documentationRelease = AsyncGate()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            documentationSearchResponder: { requestData in
                documentationStarted.signal()
                try await documentationRelease.wait()
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cancelled\"}"
                )
            }
        )
        sessionManager.setInitialized(true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let service = ClientMCPRequestExecutor(
                config: config.runtime,
                sessionManager: sessionManager,
                refreshCodeIssuesCoordinator: .makeDefault(),
                refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                    defaultRequestTimeoutSeconds: config.requestTimeout
                )
            )
            let payload = toolsCallPayload(
                id: 720,
                name: "DocumentationSearch",
                arguments: [
                    "query": "UIView",
                ]
            )
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
            let operation = service.handle(
                bodyData: bodyData,
                headerSessionID: "session-docs-single-cancel",
                headerSessionExists: true,
                prefersEventStream: false,
                eventLoop: group.next()
            )
            let cancellationHandle = try #require(operation.cancellationHandle)

            try await documentationStarted.wait(
                timeout: .seconds(1),
                description: "waiting for documentation search to start"
            )
            service.cancel(cancellationHandle)
            await documentationRelease.signal()

            do {
                _ = try await operation.future.get()
                Issue.record("cancelled documentation request should not complete successfully")
            } catch {
                #expect(error is CancellationError)
            }
            let abandonedLease = try #require(
                sessionManager.leaseDebugSnapshots().first { $0.state == .abandoned }
            )
            #expect(abandonedLease.releaseReason == "clientDisconnected")
            #expect(sessionManager.sentToolNames().isEmpty)
            try await shutdown(group)
        } catch {
            await documentationRelease.signal()
            try? await shutdown(group)
            throw error
        }
    }

    @Test func httpResourcesListReturnsEmptyArray() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-1")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-1")
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseID = (object?["id"] as? NSNumber)?.intValue
        #expect(responseID == 1)
        let result = object?["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }

    @Test func httpSingleItemBatchResourcesListIsRejected() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-batch-resources")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        try postJSONArray(payload, sessionID: "session-batch-resources", to: channel)

        let response = try await collectResponse(from: channel)
        assertBatchRejected(response)
    }
}
