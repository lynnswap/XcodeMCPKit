import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import XcodeMCPRuntime
import XcodeMCPTestSupport

@testable import XcodeMCPProxyKit

extension HTTPHandlerTests {
    @Test func httpDisabledToolCallReturnsLocalToolErrorWhenNoUpstreamIsAvailable() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("disabled tool call should not reach upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndex(nil)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-disabled-tool-no-upstream",
                payload: toolsCallPayload(
                    id: 111,
                    name: "RunAllTests",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "tool 'RunAllTests' is disabled by proxy config")
            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolNotificationReturnsAcceptedWithoutUpstream() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("disabled tool notification should not reach upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let rawResponse = try await postHTTPData(
                url: server.url,
                sessionID: "session-disabled-notification",
                payload: [
                    "jsonrpc": "2.0",
                    "method": "tools/call",
                    "params": [
                        "name": "RunAllTests",
                        "arguments": [:],
                    ],
                ]
            )

            #expect(rawResponse.statusCode == 202)
            #expect(rawResponse.bodyData.isEmpty)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchDropsDisabledNotificationBeforeForwardingAllowedCalls() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                if method == "tools/list" {
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "tools": [Any]()
                            ]
                        )
                    )
                }
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
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-disabled-notification-mixed",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    toolsCallPayload(
                        id: 441,
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

    @Test func httpDisabledToolBatchReturnsLocalAndQueueErrorsWhenNoUpstreamIsAvailable() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { _, _, _ in
                Issue.record("batch should fail before reaching upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndex(nil)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-disabled-batch-no-upstream",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 211,
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "id": 212,
                        "method": "tools/call",
                        "params": [
                            "name": "XcodeListWindows",
                            "arguments": [:],
                        ],
                    ],
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolBatchReturnsLocalErrorsAndForwardsAllowedRequests() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests", "RunSomeTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                if method == "tools/list" {
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "tools": [Any]()
                            ]
                        )
                    )
                }
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListWindows")
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "allowed"))
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
                sessionID: "session-disabled-batch",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 201,
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "RunSomeTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "id": 202,
                        "method": "tools/call",
                        "params": [
                            "name": "XcodeListWindows",
                            "arguments": [:],
                        ],
                    ],
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

    @Test func httpDisabledToolBatchReturnsLocalOnlyResponseWhenAllRequestsAreBlocked() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests", "RunSomeTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("all-blocked batch should not reach upstream")
                return .immediate(Data())
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
                sessionID: "session-disabled-all-blocked",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 301,
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "RunSomeTests",
                            "arguments": [:],
                        ],
                    ],
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

    @Test func httpDisabledToolNamesDoNotBlockInternalRefreshWorkflowCalls() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        config.disabledToolNames = ["XcodeListWindows"]
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("App/Sources/App.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-disabled-internal, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}"
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [
                                        [
                                            "path": target.path,
                                            "message": "target warning",
                                            "line": 12,
                                            "severity": "warning",
                                        ]
                                    ],
                                    "totalFound": 1,
                                    "truncated": false,
                                ],
                            ]
                        )
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
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
                sessionID: "session-disabled-internal",
                payload: toolsCallPayload(
                    id: 401,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-disabled-internal",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect(issues?.count == 1)
            #expect(issues?.first?["path"] as? String == target.path)
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
            ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}
