import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import ProxyCore
import ProxyMCP
import ProxySession
import ProxyXcodeFeatures
 import ProxyXcodeSupport
import XcodeMCPTestSupport

@testable import ProxyHTTPGateway

extension HTTPHandlerTests {
    @Test func httpDocumentationSearchFallsThroughWhenNoDocumentationProviderExists() async throws {
        let config = makeConfig(requestTimeout: 2)
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
        let config = makeConfig(requestTimeout: 2)
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
                let originalID = try #require(RPCID(any: originalIDValue))
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

    @Test func httpDocumentationSearchFallsBackWhenInactiveProviderIsUnavailable() async throws {
        let config = makeConfig(requestTimeout: 2)
        let localDocumentationRequests = NIOLockedValueBox(0)
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
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotAcquisitionError.unavailable
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
                sessionID: "session-docs-inactive-fallback",
                payload: toolsCallPayload(
                    id: 66,
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
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchFallsThroughWhenNoDocumentationProviderExists() async throws {
        let config = makeConfig(requestTimeout: 2)
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
            let (response, bodyData) = try await postHTTPAnyJSON(
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

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)
            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 63 }
            let docsResult = docs?["result"] as? [String: Any]
            let docsContent = docsResult?["content"] as? [[String: Any]]
            #expect(docsContent?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")
            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 64 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")
            #expect(sessionManager.sentToolNames() == ["DocumentationSearch", "OtherAllowedTool"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchRoutesDocumentationSearchThroughProviderAndForwardsOtherCalls() async throws {
        let config = makeConfig(requestTimeout: 2)
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
                let originalID = try #require(RPCID(any: originalIDValue))
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
            let (response, bodyData) = try await postHTTPAnyJSON(
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

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 701 }
            let docsResult = docs?["result"] as? [String: Any]
            let structuredContent = docsResult?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "docs")

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 702 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
            #expect(documentationRequests.withLockedValue { $0 } == ["UIView animate"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchForwardsDocumentationSearchNotificationWithProvider() async throws {
        let config = makeConfig(requestTimeout: 2)
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
                let originalID = try #require(RPCID(any: originalIDValue))
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
            let (response, bodyData) = try await postHTTPAnyJSON(
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

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 1)

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 703 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentToolNames() == [
                "DocumentationSearch",
                "OtherAllowedTool",
            ])
            #expect(documentationRequests.withLockedValue { $0 }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchForwardsOtherCallsWhileDocumentationSearchIsStillResolving() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationStarted = NIOLockedValueBox(false)
        let releaseDocumentation = DispatchSemaphore(value: 0)
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
                documentationStarted.withLockedValue { $0 = true }
                _ = releaseDocumentation.wait(timeout: .now() + 2)
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
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
        defer {
            releaseDocumentation.signal()
        }

        do {
            let postTask = Task {
                try await postHTTPAnyData(
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
            }

            let didStartDocumentation = await waitUntil(timeout: .seconds(1)) {
                documentationStarted.withLockedValue { $0 }
            }
            #expect(didStartDocumentation)
            let didForwardOtherTool = await waitUntil(timeout: .seconds(1)) {
                sessionManager.sentToolNames() == ["OtherAllowedTool"]
            }
            #expect(didForwardOtherTool)
            releaseDocumentation.signal()

            let rawResponse = try await postTask.value
            #expect(rawResponse.statusCode == 200)
            let bodyData = try JSONSerialization.jsonObject(
                with: rawResponse.bodyData,
                options: []
            )
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)
            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 721 }
            let docsResult = docs?["result"] as? [String: Any]
            let structuredContent = docsResult?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "docs")
            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 722 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchToolsListUsesLocalToolSurfaceAndForwardsOtherCalls() async throws {
        let config = makeConfig(requestTimeout: 2)
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
            let (response, bodyData) = try await postHTTPAnyJSON(
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

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let toolsList = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 731 }
            let toolsResult = toolsList?["result"] as? [String: Any]
            let tools = try #require(toolsResult?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String }.contains("DocumentationSearch"))

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 732 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentMethods() == ["tools/call"])
            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchRoutesDocumentationSearchAfterSameBatchToolsListActivatesProvider() async throws {
        let config = makeConfig(requestTimeout: 2)
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
                let originalID = try #require(RPCID(any: originalIDValue))
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
            let (response, bodyData) = try await postHTTPAnyJSON(
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

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 3)

            let toolsList = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 741 }
            let toolsResult = toolsList?["result"] as? [String: Any]
            let tools = try #require(toolsResult?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String }.contains("DocumentationSearch"))

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 742 }
            let docsResult = docs?["result"] as? [String: Any]
            let structuredContent = docsResult?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "docs")

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 743 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
            #expect(documentationRequests.withLockedValue { $0 } == ["UIView same batch"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchFallsBackDocumentationSearchWhenSameBatchToolsListDoesNotActivateProvider()
        async throws
    {
        let config = makeConfig(requestTimeout: 2)
        let localDocumentationRequests = NIOLockedValueBox(0)
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
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotAcquisitionError.unavailable
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
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-tools-list-docs-fallback",
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
                            "query": "UIView same batch fallback",
                        ]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let toolsList = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 751 }
            let toolsResult = toolsList?["result"] as? [String: Any]
            let tools = try #require(toolsResult?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String }.contains("DocumentationSearch") == false)

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 752 }
            let docsResult = docs?["result"] as? [String: Any]
            let docsContent = docsResult?["content"] as? [[String: Any]]
            #expect(docsContent?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")

            #expect(sessionManager.sentToolNames() == ["DocumentationSearch"])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchStartsDocumentationFallbackBeforeOtherForwardedRequestTimesOut()
        async throws
    {
        let config = makeConfig(requestTimeout: 0.25)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let fallbackDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                if toolName == "DocumentationSearch" {
                    fallbackDocumentationRequests.withLockedValue { $0 += 1 }
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
                throw UpstreamSlotAcquisitionError.unavailable
            }
        )
        sessionManager.setAvailableUpstreamIndices([0, 1])
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-docs-fallback-before-other-timeout",
                payload: [
                    toolsCallPayload(
                        id: 761,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView fallback before timeout",
                        ]
                    ),
                    toolsCallPayload(
                        id: 762,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 761 }
            let docsResult = docs?["result"] as? [String: Any]
            let docsContent = docsResult?["content"] as? [[String: Any]]
            #expect(docsContent?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 762 }
            let otherError = other?["error"] as? [String: Any]
            #expect(otherError?["message"] as? String == "upstream timeout")

            #expect(sessionManager.sentToolRequests() == [
                "OtherAllowedTool@0",
                "DocumentationSearch@1",
            ])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
            #expect(fallbackDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchSharesSingleDeadline() async throws {
        let config = makeConfig(requestTimeout: 0.1)
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
                Thread.sleep(forTimeInterval: 0.2)
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
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
            let (response, bodyData) = try await postHTTPAnyJSON(
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

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let first = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 711 }
            #expect(first?["result"] != nil)

            let second = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 712 }
            let secondError = try #require(second?["error"] as? [String: Any])
            #expect((secondError["code"] as? NSNumber)?.intValue == -32000)
            #expect(secondError["message"] as? String == "upstream timeout")
            #expect(documentationRequests.withLockedValue { $0 } == ["first"])
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpSingleDocumentationSearchCancellationAbandonsPrefilterLease() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationStarted = DispatchSemaphore(value: 0)
        let documentationRelease = DispatchSemaphore(value: 0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            documentationSearchResponder: { requestData in
                documentationStarted.signal()
                _ = documentationRelease.wait(timeout: .now() + 2)
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cancelled\"}"
                )
            }
        )
        sessionManager.setInitialized(true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let service = HTTPPostService(
                config: config,
                sessionManager: sessionManager,
                refreshCodeIssuesCoordinator: .makeDefault(),
                refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState(
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

            try #require(await waitForHTTPTestSemaphore(documentationStarted, timeoutSeconds: 1) == .success)
            service.cancel(cancellationHandle)
            documentationRelease.signal()

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
            try await group.shutdownGracefully()
        } catch {
            documentationRelease.signal()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func httpBatchDocumentationSearchCancellationAbandonsPrefilterLease() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationStarted = DispatchSemaphore(value: 0)
        let documentationRelease = DispatchSemaphore(value: 0)
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
                _ = documentationRelease.wait(timeout: .now() + 2)
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cancelled\"}"
                )
            }
        )
        sessionManager.setInitialized(true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let service = HTTPPostService(
                config: config,
                sessionManager: sessionManager,
                refreshCodeIssuesCoordinator: .makeDefault(),
                refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState(
                    defaultRequestTimeoutSeconds: config.requestTimeout
                )
            )
            let payload: [[String: Any]] = [
                toolsCallPayload(
                    id: 721,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "UIView",
                    ]
                ),
                toolsCallPayload(
                    id: 722,
                    name: "OtherAllowedTool",
                    arguments: [:]
                ),
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
            let operation = service.handle(
                bodyData: bodyData,
                headerSessionID: "session-docs-batch-cancel",
                headerSessionExists: true,
                prefersEventStream: false,
                eventLoop: group.next()
            )
            let cancellationHandle = try #require(operation.cancellationHandle)

            try #require(await waitForHTTPTestSemaphore(documentationStarted, timeoutSeconds: 1) == .success)
            service.cancel(cancellationHandle)
            documentationRelease.signal()

            do {
                _ = try await operation.future.get()
                Issue.record("cancelled documentation batch should not complete successfully")
            } catch {
                #expect(error is CancellationError)
            }
            let abandonedLease = try #require(
                sessionManager.leaseDebugSnapshots().first { $0.state == .abandoned }
            )
            #expect(abandonedLease.releaseReason == "clientDisconnected")
            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
            try await group.shutdownGracefully()
        } catch {
            documentationRelease.signal()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func httpResourcesListReturnsEmptyArray() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-1")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
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

    @Test func httpSingleItemBatchResourcesListReturnsEmptyArray() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-batch-resources")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let responseArray =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [[String: Any]]
        let responseObject = try #require(responseArray?.first)
        #expect((responseObject["id"] as? NSNumber)?.intValue == 1)
        let result = responseObject["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }
}
