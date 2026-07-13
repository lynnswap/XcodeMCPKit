import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
@testable import XcodeMCPProxyRuntime
import Testing
import XcodeMCPProxyTestSupport


private func jsonRPCError(
    from resolution: ClientMCPRequestExecutor.Resolution
) throws -> (code: Int?, message: String?) {
    switch resolution {
    case .responseData(let data, _, _):
        let body =
            (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            ?? [:]
        let error = body["error"] as? [String: Any]
        return ((error?["code"] as? NSNumber)?.intValue, error?["message"] as? String)
    case .mcpError(_, let code, let message, _, _):
        return (code, message)
    case .plain(let status, let body, _):
        Issue.record("expected JSON-RPC response, got plain \(status): \(body)")
        return (Int(status.code), body)
    case .empty(let status, _):
        Issue.record("expected JSON-RPC response, got empty \(status)")
        return (Int(status.code), nil)
    }
}

extension HTTPHandlerTests {
    @Test func httpRefreshCodeIssuesUsesNavigatorIssuesProxyByDefault() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                                "{\"message\":\"* tabIdentifier: windowtab-proxy, workspacePath: \(workspacePath)\"}"
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
                                        "text":
                                            "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"},{\"path\":\"\(temporaryRoot)/Other.swift\",\"message\":\"other warning\",\"line\":99,\"severity\":\"warning\"}],\"totalFound\":2,\"truncated\":false}",
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [
                                        [
                                            "path": target.path,
                                            "message": "target warning",
                                            "line": 12,
                                            "severity": "warning",
                                        ],
                                        [
                                            "path": "\(temporaryRoot)/Other.swift",
                                            "message": "other warning",
                                            "line": 99,
                                            "severity": "warning",
                                        ],
                                    ],
                                    "totalFound": 2,
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
        sessionManager.setAvailableUpstreamIndices([1, 0, 0])
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-proxy",
                payload: toolsCallPayload(
                    id: 30,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-proxy",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)
            #expect(issues?.count == 1)
            #expect(issues?.first?["path"] as? String == target.path)
            #expect(issues?.first?["message"] as? String == "target warning")
            #expect(
                sessionManager.sentToolNames() == [
                    "XcodeListWindows",
                    "XcodeListNavigatorIssues",
                ])
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
            let sentToolRequests = sessionManager.sentToolRequests()
            #expect(sentToolRequests.count == 2)
            #expect(sentToolRequests.contains { $0.hasPrefix("XcodeListWindows@") })
            #expect(sentToolRequests.contains { $0.hasPrefix("XcodeListNavigatorIssues@") })
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpSingleElementBatchRefreshCodeIssuesUsesNavigatorIssuesProxyByDefault()
        async throws
    {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                                "{\"message\":\"* tabIdentifier: windowtab-proxy-batch, workspacePath: \(workspacePath)\"}"
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
                                        "text":
                                            "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
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
        sessionManager.setAvailableUpstreamIndices([1, 0, 0])
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-proxy-batch",
                payload: [
                    toolsCallPayload(
                        id: 130,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-batch",
                            "filePath": "App/Sources/App.swift",
                        ]
                    )
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

    @Test func httpMixedBatchKeepsRefreshProxyAndAllowedResponses() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                if method == "tools/call" {
                    switch toolName {
                    case "XcodeListWindows":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-proxy-mixed, workspacePath: \(workspacePath)\"}"
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
                                            "text":
                                                "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
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
                    case "OtherAllowedTool":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text: "other-tool-result"
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
                sessionID: "session-proxy-mixed",
                payload: [
                    toolsCallPayload(
                        id: 230,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-mixed",
                            "filePath": "App/Sources/App.swift",
                        ]
                    ),
                    toolsCallPayload(
                        id: 231,
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

    @Test func httpMixedBatchReturnsInvalidRequestForScalarLeftoverAfterRefreshSplit() async throws
    {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                if method == "tools/call" {
                    switch toolName {
                    case "XcodeListWindows":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-proxy-scalar-leftover, workspacePath: \(workspacePath)\"}"
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
                                            "text":
                                                "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
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
                sessionID: "session-proxy-scalar-leftover",
                payload: [
                    toolsCallPayload(
                        id: 330,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-scalar-leftover",
                            "filePath": "App/Sources/App.swift",
                        ]
                    ),
                    NSNull(),
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

    @Test func httpMixedBatchPreservesNotificationLeftoverWhenScalarIsStripped() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                switch method {
                case "tools/call":
                    switch toolName {
                    case "XcodeListWindows":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-proxy-notification-leftover, workspacePath: \(workspacePath)\"}"
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
                                            "text":
                                                "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
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
                default:
                    return .immediate(Data())
                }
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
                sessionID: "session-proxy-notification-leftover",
                payload: [
                    toolsCallPayload(
                        id: 340,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-notification-leftover",
                            "filePath": "App/Sources/App.swift",
                        ]
                    ),
                    [
                        "jsonrpc": "2.0",
                        "method": "notifications/progress",
                        "params": [
                            "value": "tick"
                        ],
                    ],
                    NSNull(),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentMethods().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchForwardsRefreshNotificationThroughNormalPath() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                switch (method, toolName) {
                case ("tools/call", "RunAllTests"):
                    return .immediate(
                        try makeToolSuccessResponse(id: originalID, text: "ok")
                    )
                case ("tools/call", "XcodeRefreshCodeIssuesInFile"):
                    return .immediate(Data())
                default:
                    return .immediate(
                        try makeToolErrorResponse(id: originalID, text: "unexpected tool")
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
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-refresh-notification-forwarding",
                payload: [
                    toolsCallPayload(
                        id: 510,
                        name: "RunAllTests",
                        arguments: [:]
                    ),
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "XcodeRefreshCodeIssuesInFile",
                            "arguments": [
                                "tabIdentifier": "windowtab-notification",
                                "filePath": "App/Sources/App.swift",
                            ],
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

    @Test func httpMixedBatchRefreshRetryDoesNotReplayAllowedCalls() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let refreshAttempts = NIOLockedValueBox(0)
        let otherAttempts = NIOLockedValueBox(0)

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
                switch toolName {
                case "XcodeRefreshCodeIssuesInFile":
                    let attempt = refreshAttempts.withLockedValue { value in
                        value += 1
                        return value
                    }
                    if attempt == 1 {
                        return .immediate(
                            try makeToolErrorResponse(
                                id: originalID,
                                text:
                                    "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                            )
                        )
                    }
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "refresh-ok"
                        )
                    )
                case "OtherAllowedTool":
                    otherAttempts.withLockedValue { value in
                        value += 1
                    }
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "other-tool-result"
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
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: "session-upstream-mixed-retry",
                payload: [
                    toolsCallPayload(
                        id: 232,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-upstream-mixed-retry",
                            "filePath": "App.swift",
                        ]
                    ),
                    toolsCallPayload(
                        id: 233,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(refreshAttempts.withLockedValue { $0 } == 0)
            #expect(otherAttempts.withLockedValue { $0 } == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenWindowLookupFailsAfterPreviousSuccess()
        async throws
    {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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

        let windowLookups = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    let lookupCount = windowLookups.withLockedValue { value in
                        value += 1
                        return value
                    }
                    if lookupCount == 1 {
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-window-lookup-fallback, workspacePath: \(workspacePath)\"}"
                            )
                        )
                    }
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "windows unavailable"
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
                                        "text":
                                            "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
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
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "upstream-after-window-lookup-failure"
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
            let (firstResponse, firstBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-window-lookup-fallback",
                payload: toolsCallPayload(
                    id: 30,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-window-lookup-fallback",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(firstResponse.statusCode == 200)
            let firstResult = firstBody["result"] as? [String: Any]
            let firstStructuredContent = firstResult?["structuredContent"] as? [String: Any]
            #expect((firstStructuredContent?["totalFound"] as? NSNumber)?.intValue == 1)

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-window-lookup-fallback",
                payload: toolsCallPayload(
                    id: 31,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-window-lookup-fallback",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let secondResult = secondBody["result"] as? [String: Any]
            let secondContent = secondResult?["content"] as? [[String: Any]]
            #expect(
                secondContent?.first?["text"] as? String == "upstream-after-window-lookup-failure")
            #expect(
                sessionManager.sentToolNames() == [
                    "XcodeListWindows",
                    "XcodeListNavigatorIssues",
                    "XcodeListWindows",
                    "XcodeRefreshCodeIssuesInFile",
                ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenNavigatorIssuesAreTruncated()
        async throws
    {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                                "{\"message\":\"* tabIdentifier: windowtab-truncated, workspacePath: \(workspacePath)\"}"
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
                                        "text":
                                            "{\"issues\":[],\"totalFound\":0,\"truncated\":true}",
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [],
                                    "totalFound": 0,
                                    "truncated": true,
                                ],
                            ]
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "upstream-after-truncated-navigator"
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
                sessionID: "session-truncated-navigator",
                payload: toolsCallPayload(
                    id: 19,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-truncated",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-truncated-navigator")
            #expect(
                sessionManager.sentToolNames() == [
                    "XcodeListWindows",
                    "XcodeListNavigatorIssues",
                    "XcodeRefreshCodeIssuesInFile",
                ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenResolverCannotFindTarget() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

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
                                "{\"message\":\"* tabIdentifier: windowtab-fallback, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(id: originalID, text: "upstream-result")
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
                sessionID: "session-fallback-resolver",
                payload: toolsCallPayload(
                    id: 31,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-fallback",
                        "filePath": "Missing.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-result")
            #expect(
                sessionManager.sentToolNames() == [
                    "XcodeListWindows",
                    "XcodeRefreshCodeIssuesInFile",
                ])
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenNavigatorIssuesFails() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
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
                                "{\"message\":\"* tabIdentifier: windowtab-navigator-fallback, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "navigator failed"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID, text: "upstream-after-navigator-failure")
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
                sessionID: "session-navigator-fallback",
                payload: toolsCallPayload(
                    id: 32,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-navigator-fallback",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-navigator-failure")
            #expect(
                sessionManager.sentToolNames() == [
                    "XcodeListWindows",
                    "XcodeListNavigatorIssues",
                    "XcodeRefreshCodeIssuesInFile",
                ])
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func refreshWorkflowFallsBackToUpstreamWhenNavigatorIssuesTimesOut() async throws {
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

        let config = makeHTTPConfig(requestTimeout: 1)
        let coordinator = RefreshCodeIssues.Coordinator()
        let debugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
        let workflow = RefreshCodeIssues.Workflow(
            mode: .proxy,
            requestTimeout: config.requestTimeout,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssues.TargetResolver(),
            debugState: debugState,
            windowLookupTimeout: 0.2,
            navigatorIssuesTimeout: 0.05,
            logger: ProxyLogging.make("test.refresh")
        )
        let observedTimeouts = NIOLockedValueBox<[Int64]>([])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = JSONRPC.ID(any: NSNumber(value: 33))!
        let requestPayload = toolsCallPayload(
            id: 33,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-navigator-timeout",
                "filePath": "App/Sources/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])
        let upstreamFallbackData = try makeToolSuccessResponse(
            id: requestID,
            text: "upstream-after-navigator-timeout"
        )

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssues.Request(
                tabIdentifier: "windowtab-navigator-timeout",
                filePath: "App/Sources/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-navigator-timeout",
            responseID: requestID,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-navigator-timeout",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, _, _, _, _, requestTimeoutOverride in
                guard name == "XcodeListNavigatorIssues" else {
                    return .unavailable
                }
                observedTimeouts.withLockedValue { values in
                    values.append(requestTimeoutOverride?.nanoseconds ?? -1)
                }
                return .timeout
            },
            forwarder: { _, _, _, _, _, _ in
                .success(upstreamFallbackData)
            }
        )

        switch result {
        case .success(let responseData):
            let object = try #require(
                JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
            )
            let responseResult: [String: Any]? = object["result"] as? [String: Any]
            let content: [[String: Any]]? = responseResult?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-navigator-timeout")
        default:
            Issue.record("expected workflow to fall back to upstream after navigator timeout")
        }

        #expect(observedTimeouts.withLockedValue { $0.first } == 50_000_000)
    }

    @Test func refreshWorkflowDoesNotFabricateNavigatorTimeoutWhenRequestTimeoutIsDisabled()
        async throws
    {
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

        let config = makeHTTPConfig(requestTimeout: 0)
        let coordinator = RefreshCodeIssues.Coordinator()
        let debugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
        let workflow = RefreshCodeIssues.Workflow(
            mode: .proxy,
            requestTimeout: config.requestTimeout,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssues.TargetResolver(),
            debugState: debugState,
            windowLookupTimeout: 0.2,
            navigatorIssuesTimeout: 0.05,
            logger: ProxyLogging.make("test.refresh")
        )
        let observedTimeouts = NIOLockedValueBox<[Int64]>([])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = JSONRPC.ID(any: NSNumber(value: 133))!
        let requestPayload = toolsCallPayload(
            id: 133,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-unbounded-timeout",
                "filePath": "App/Sources/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssues.Request(
                tabIdentifier: "windowtab-unbounded-timeout",
                filePath: "App/Sources/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-unbounded-timeout",
            responseID: requestID,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-unbounded-timeout",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, _, _, _, _, requestTimeoutOverride in
                guard name == "XcodeListNavigatorIssues" else {
                    return .unavailable
                }
                observedTimeouts.withLockedValue { values in
                    values.append(requestTimeoutOverride?.nanoseconds ?? -1)
                }
                return .success([
                    "content": [
                        [
                            "type": "text",
                            "text":
                                "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
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
                ])
            },
            forwarder: { _, _, _, _, _, _ in
                Issue.record("unbounded timeout should not fall back to upstream")
                return .invalidRequest
            }
        )

        switch result {
        case .success(let responseData):
            let object = try #require(
                JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
            )
            let responseResult = object["result"] as? [String: Any]
            let structuredContent = responseResult?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)
            #expect(issues?.first?["path"] as? String == target.path)
        default:
            Issue.record("expected workflow to keep proxy path when request timeout is disabled")
        }

        #expect(observedTimeouts.withLockedValue { $0.first } == -1)
    }

    @Test func refreshWorkflowPreservesCancellationWhenNavigatorIssuesCallIsCancelled()
        async throws
    {
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

        let coordinator = RefreshCodeIssues.Coordinator()
        let debugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: 2
        )
        let workflow = RefreshCodeIssues.Workflow(
            mode: .proxy,
            requestTimeout: 2,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssues.TargetResolver(),
            debugState: debugState,
            windowLookupTimeout: 0.2,
            navigatorIssuesTimeout: 0.05,
            logger: ProxyLogging.make("test.refresh")
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = JSONRPC.ID(any: NSNumber(value: 144))!
        let requestPayload = toolsCallPayload(
            id: 144,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-cancelled-navigator",
                "filePath": "App/Sources/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssues.Request(
                tabIdentifier: "windowtab-cancelled-navigator",
                filePath: "App/Sources/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-cancelled-navigator",
            responseID: requestID,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-cancelled-navigator",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, _, _, _, _, _ in
                #expect(name == "XcodeListNavigatorIssues")
                return .cancelled
            },
            forwarder: { _, _, _, _, _, _ in
                Issue.record("cancelled navigator lookup should not fall back upstream")
                return .invalidRequest
            }
        )

        guard case .cancelled(let responseID) = result else {
            Issue.record("expected cancelled result")
            return
        }
        #expect(responseID.key == requestID.key)
    }

    @Test func refreshWorkflowPreservesBackslashesInNavigatorGlob() async throws {
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("Group\\Folder/App.swift")
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

        let config = makeHTTPConfig(requestTimeout: 1)
        let coordinator = RefreshCodeIssues.Coordinator()
        let debugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
        let workflow = RefreshCodeIssues.Workflow(
            mode: .proxy,
            requestTimeout: config.requestTimeout,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssues.TargetResolver(),
            debugState: debugState,
            logger: ProxyLogging.make("test.refresh")
        )
        let observedGlob = NIOLockedValueBox<String?>(nil)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = JSONRPC.ID(any: NSNumber(value: 233))!
        let requestPayload = toolsCallPayload(
            id: 233,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-backslash",
                "filePath": "Group\\Folder/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssues.Request(
                tabIdentifier: "windowtab-backslash",
                filePath: "Group\\Folder/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-backslash",
            responseID: requestID,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-backslash",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, arguments, _, _, _, _ in
                guard name == "XcodeListNavigatorIssues" else {
                    return .unavailable
                }
                observedGlob.withLockedValue { $0 = arguments["glob"] as? String }
                return .success([
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"issues\":[],\"totalFound\":0,\"truncated\":false}",
                        ]
                    ],
                    "structuredContent": [
                        "issues": [],
                        "totalFound": 0,
                        "truncated": false,
                    ],
                ])
            },
            forwarder: { _, _, _, _, _, _ in
                Issue.record("backslash-preserving proxy path should not fall back upstream")
                return .invalidRequest
            }
        )

        switch result {
        case .success:
            #expect(observedGlob.withLockedValue { $0 } == "**/Group\\Folder/App.swift")
        default:
            Issue.record("expected workflow to stay on proxy path for backslash-containing path")
        }
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWithUnlimitedTimeout() async throws {
        var config = makeHTTPConfig(requestTimeout: 0)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("App.swift")
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
                                "{\"message\":\"* tabIdentifier: windowtab-unlimited-timeout, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "navigator failed"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "upstream-after-unlimited-timeout-fallback"
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
                sessionID: "session-unlimited-timeout",
                payload: toolsCallPayload(
                    id: 35,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-unlimited-timeout",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(
                content?.first?["text"] as? String == "upstream-after-unlimited-timeout-fallback")
            #expect(
                sessionManager.sentToolNames() == [
                    "XcodeListWindows",
                    "XcodeListNavigatorIssues",
                    "XcodeRefreshCodeIssuesInFile",
                ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesRetriesSourceEditorErrorFive() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesClock: .testValue
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-retry",
                payload: toolsCallPayload(
                    id: 10,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpSingleElementBatchRefreshCodeIssuesRetriesSourceEditorErrorFive() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "ok"))
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
                sessionID: "session-retry-batch",
                payload: [
                    toolsCallPayload(
                        id: 110,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-retry-batch",
                            "filePath": "App.swift",
                        ]
                    )
                ]
            )
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentUpstreamCount() == 0)
            #expect(attempts.withLockedValue { $0 } == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesRetriesShortSourceEditorErrorFiveText() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesClock: .testValue
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-retry-short",
                payload: toolsCallPayload(
                    id: 13,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-short",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesDoesNotRetryNonRetryableToolError() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalID,
                        text: "permission denied"
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
                sessionID: "session-no-retry",
                payload: toolsCallPayload(
                    id: 11,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-no-retry",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpNonTargetToolsCallDoesNotUseRefreshRetryPath() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalID,
                        text:
                            "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
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
                sessionID: "session-other-tool",
                payload: toolsCallPayload(
                    id: 12,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolCallReturnsLocalToolErrorWithoutUpstream() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("disabled tool call should not reach upstream")
                return .immediate(Data())
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
                sessionID: "session-disabled-tool",
                payload: toolsCallPayload(
                    id: 101,
                    name: "RunAllTests",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            let content = result?["content"] as? [[String: Any]]
            #expect(
                content?.first?["text"] as? String
                    == "tool 'RunAllTests' is disabled by proxy config")
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesQueuesBurstForSameTabWithoutBackpressureError() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let firstSent = SyncSignal()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                firstSent.signal()
                return .manual(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(eventLoopGroup) }
        let service = ClientMCPRequestExecutor(
            config: config.runtime,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        var operations: [ClientMCPRequestExecutor.Operation] = []

        do {
            let requestCount = 6
            operations = try (0..<requestCount).map { index in
                let payload = toolsCallPayload(
                    id: 21 + index,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-overload",
                        "filePath": "File\(index).swift",
                    ]
                )
                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                return service.handle(
                    bodyData: data,
                    headerSessionID: "session-overload-\(index)",
                    headerSessionExists: true,
                    prefersEventStream: false,
                    eventLoop: eventLoopGroup.next()
                )
            }

            try await firstSent.wait(description: "waiting for first upstream refresh request")
            try await sessionManager.waitForPendingResponseCount(1)
            #expect(sessionManager.sentUpstreamCount() == 1)
            #expect(sessionManager.pendingResponseCount() == 1)

            for expectedCount in 1...requestCount {
                #expect(sessionManager.sentUpstreamCount() == expectedCount)
                #expect(sessionManager.pendingResponseCount() == 1)
                try sessionManager.deliverNextPendingResponse()
                if expectedCount < requestCount {
                    try await sessionManager.waitForPendingResponseCount(1)
                    #expect(sessionManager.sentUpstreamCount() == expectedCount + 1)
                    #expect(sessionManager.pendingResponseCount() == 1)
                }
            }

            for operation in operations {
                let resolution = try await operation.future.get()
                let (errorCode, errorMessage) = try jsonRPCError(from: resolution)
                #expect(errorCode == nil)
                #expect(errorMessage == nil)
            }
            #expect(sessionManager.sentUpstreamCount() == requestCount)
        } catch {
            for operation in operations {
                operation.cancellationHandle?.cancel(using: sessionManager)
            }
            throw error
        }
    }

    @Test func httpRefreshProxyQueuesBurstForSameTabWithoutBackpressureError() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("Missing.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)
        let firstSent = SyncSignal()

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
                                "{\"message\":\"* tabIdentifier: windowtab-proxy-overload, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    firstSent.signal()
                    return .manual(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [
                                    [
                                        "type": "text",
                                        "text":
                                            "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"warn\",\"line\":1,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}",
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [
                                        [
                                            "path": target.path,
                                            "message": "warn",
                                            "line": 1,
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
                        try makeToolErrorResponse(id: originalID, text: "unexpected tool"))
                }
            }
        )
        sessionManager.setInitialized(true)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(eventLoopGroup) }
        let service = ClientMCPRequestExecutor(
            config: config.runtime,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        var operations: [ClientMCPRequestExecutor.Operation] = []

        do {
            let requestCount = 6
            operations = try (0..<requestCount).map { index in
                let payload = toolsCallPayload(
                    id: 26 + index,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-proxy-overload",
                        "filePath": "Missing.swift",
                    ]
                )
                let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                return service.handle(
                    bodyData: data,
                    headerSessionID: "session-proxy-overload-\(index)",
                    headerSessionExists: true,
                    prefersEventStream: false,
                    eventLoop: eventLoopGroup.next()
                )
            }

            try await firstSent.wait(description: "waiting for first proxy refresh request")
            try await sessionManager.waitForPendingResponseCount(1)
            #expect(sessionManager.sentUpstreamCount() == 2)
            #expect(sessionManager.pendingResponseCount() == 1)

            for expectedRequests in 1...requestCount {
                #expect(sessionManager.sentUpstreamCount() == expectedRequests * 2)
                #expect(sessionManager.pendingResponseCount() == 1)
                try sessionManager.deliverNextPendingResponse()
                if expectedRequests < requestCount {
                    try await sessionManager.waitForPendingResponseCount(1)
                    #expect(sessionManager.sentUpstreamCount() == (expectedRequests + 1) * 2)
                    #expect(sessionManager.pendingResponseCount() == 1)
                }
            }

            for operation in operations {
                let resolution = try await operation.future.get()
                let (errorCode, errorMessage) = try jsonRPCError(from: resolution)
                #expect(errorCode == nil)
                #expect(errorMessage == nil)
            }
            #expect(sessionManager.sentUpstreamCount() == requestCount * 2)
        } catch {
            for operation in operations {
                operation.cancellationHandle?.cancel(using: sessionManager)
            }
            throw error
        }
    }

    @Test func refreshWorkflowReturnsStandardTimeoutWhenPermitWaitConsumesRequestDeadline()
        async throws
    {
        let clock = TestClock()
        let coordinator = RefreshCodeIssues.Coordinator(waitClock: clock)
        let debugState = RefreshCodeIssues.DebugState(defaultRequestTimeoutSeconds: 2)
        let workflow = RefreshCodeIssues.Workflow(
            mode: .upstream,
            requestTimeout: 2,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssues.TargetResolver(),
            debugState: debugState,
            logger: ProxyLogging.make("test.refresh")
        )
        let activeStarted = TestSignal()
        let releaseFirst = TestSignal()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }

        let activeTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-timeout",
                requestTimeout: nil
            ) { _ in
                activeStarted.signal()
                try await releaseFirst.wait(description: "waiting to release first request")
            }
        }
        try await activeStarted.wait(description: "waiting for active queued-timeout execution")

        let requestID = JSONRPC.ID(any: NSNumber(value: 25))!
        let requestPayload = toolsCallPayload(
            id: 25,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-timeout",
                "filePath": "B.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let requestTask = Task {
            await workflow.run(
                refreshRequest: RefreshCodeIssues.Request(
                    tabIdentifier: "windowtab-timeout",
                    filePath: "B.swift"
                ),
                bodyData: requestData,
                sessionID: "session-timeout-2",
                responseID: requestID,
                requestTimeoutOverride: .milliseconds(50),
                eventLoop: group.next(),
                windowsProvider: { _, _, _, _ in
                    Issue.record("queued timeout should not resolve windows")
                    return nil
                },
                internalUpstreamChooser: { _ in
                    Issue.record("queued timeout should not choose an internal upstream")
                    return nil
                },
                internalToolCaller: { _, _, _, _, _, _ in
                    Issue.record("queued timeout should not call internal tools")
                    return .unavailable
                },
                forwarder: { _, _, _, _, _, _ in
                    Issue.record("queued timeout should not reach upstream forwarding")
                    return .invalidRequest
                }
            )
        }

        try await waitForSuspendedSleepers(on: clock)
        clock.advance(by: .milliseconds(50))

        let result = await requestTask.value
        guard case .timeout(let responseID) = result else {
            Issue.record("expected queued refresh to return standard timeout")
            releaseFirst.signal()
            _ = await activeTask.value
            return
        }
        #expect(responseID.key == requestID.key)

        releaseFirst.signal()
        _ = await activeTask.value
    }

    @Test func refreshForwarderClassifiesStaleSendAsUpstreamUnavailable() async throws {
        let config = makeHTTPConfig(requestTimeout: 1)
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setInitialized(true)
        sessionManager.rejectNextUpstreamSend()
        let executor = ClientMCPRequestExecutor(
            config: config.runtime,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        let responseID = try #require(JSONRPC.ID(any: NSNumber(value: 4201)))
        let bodyData = try JSONSerialization.data(
            withJSONObject: toolsCallPayload(
                id: 4201,
                name: "XcodeRefreshCodeIssuesInFile",
                arguments: ["tabIdentifier": "tab-stale", "filePath": "File.swift"]
            ),
            options: []
        )
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-refresh-stale",
            label: "tools/call:XcodeRefreshCodeIssuesInFile",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let eventLoop = EmbeddedEventLoop()

        let result = await executor.forwardOnce(
            bodyData: bodyData,
            sessionID: descriptor.sessionID,
            responseID: responseID,
            shouldRequeueLeaseOnRetryableFailure: { false },
            eventLoop: eventLoop,
            leaseID: leaseID,
            cancellationHandle: nil
        )

        guard case .upstreamUnavailable(let returnedID) = result else {
            Issue.record("expected stale admission to be upstream unavailable")
            return
        }
        #expect(returnedID.key == responseID.key)
        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
        #expect(sessionManager.sentUpstreamCount() == 0)
        executor.finishRefreshLease(leaseID, result: result)
    }

    @Test func httpRefreshProxyInternalToolCallsUpdateUpstreamHealthState() async throws {
        var config = makeHTTPConfig(requestTimeout: 0.2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("Missing.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)
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
                                "{\"message\":\"* tabIdentifier: windowtab-timeout, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "navigator failed"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .manual(try makeToolSuccessResponse(id: originalID, text: "late"))
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
        let forwardingService = MCPForwardingService(
            configuration: config.runtime,
            sessionManager: sessionManager
        )
        let eventLoop = EmbeddedEventLoop()

        func startInternalTool(
            id: String,
            name: String,
            arguments: [String: Any]
        ) throws -> MCPForwardingService.StartedRequest {
            let requestObject: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": [
                    "name": name,
                    "arguments": arguments,
                ],
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: requestObject, options: [])
            let parsed = try JSONSerialization.jsonObject(with: bodyData, options: [])
            let preparedRequest = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsed,
                sessionID: "session-internal-window-lookup",
                operationLeaseOverride: sessionManager.chooseUpstreamOperationLease()
            )
            let prepared = try #require(preparedRequest)
            return try forwardingService.startRequest(
                prepared,
                session: sessionManager.session(id: "session-internal-window-lookup"),
                on: eventLoop,
                requestTimeoutOverride: .milliseconds(200)
            )
        }

        func resolve(
            _ started: MCPForwardingService.StartedRequest
        ) -> MCPForwardingService.ResponseResolution {
            eventLoop.run()
            do {
                return forwardingService.resolveResponse(
                    .success(try started.future.wait()),
                    started: started,
                    sessionID: "session-internal-window-lookup"
                )
            } catch {
                return forwardingService.resolveResponse(
                    .failure(error),
                    started: started,
                    sessionID: "session-internal-window-lookup"
                )
            }
        }

        let windowsStarted = try startInternalTool(
            id: "internal-windows",
            name: "XcodeListWindows",
            arguments: [:]
        )
        eventLoop.run()
        switch resolve(windowsStarted) {
        case .success:
            break
        default:
            Issue.record("expected internal XcodeListWindows to succeed")
        }

        let navigatorStarted = try startInternalTool(
            id: "internal-navigator",
            name: "XcodeListNavigatorIssues",
            arguments: [
                "tabIdentifier": "windowtab-timeout",
                "severity": "remark",
                "glob": "**/Missing.swift",
            ]
        )
        eventLoop.run()
        switch resolve(navigatorStarted) {
        case .success:
            break
        default:
            Issue.record("expected internal XcodeListNavigatorIssues error payload to resolve")
        }

        let refreshStarted = try startInternalTool(
            id: "internal-refresh",
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-timeout",
                "filePath": target.path,
            ]
        )
        #expect(sessionManager.sentUpstreamCount() == 3)
        #expect(sessionManager.pendingResponseCount() == 1)
        eventLoop.advanceTime(by: .milliseconds(300))
        eventLoop.run()
        switch resolve(refreshStarted) {
        case .timeout:
            break
        default:
            Issue.record("expected internal XcodeRefreshCodeIssuesInFile to time out")
        }

        #expect(
            sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
                "XcodeRefreshCodeIssuesInFile",
            ])
        #expect(sessionManager.requestSuccessNotificationCount() == 2)
        #expect(sessionManager.requestTimeoutNotificationCount() == 1)
        #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
    }

    @Test func forwardingServiceInternalToolRespectsRequestedOverride()
        async throws
    {
        let config = makeHTTPConfig(requestTimeout: 0.2)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(eventLoopGroup) }
        let eventLoop = eventLoopGroup.next()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListNavigatorIssues")
                return .immediate(
                    try makeToolSuccessResponse(id: originalID, text: "{\"issues\":[]}")
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndices([1])

        let forwardingService = MCPForwardingService(
            configuration: config.runtime,
            sessionManager: sessionManager
        )

        let result = await forwardingService.callInternalTool(
            name: "XcodeListNavigatorIssues",
            arguments: ["tabIdentifier": "windowtab-1"],
            sessionID: "session-mismatch",
            eventLoop: eventLoop,
            upstreamIndexOverride: 0
        )
        switch result {
        case .success:
            break
        case .cancelled:
            Issue.record("expected the requested upstream dispatch to succeed")
        case .timeout:
            Issue.record("expected the requested upstream dispatch to succeed")
        case .unavailable:
            Issue.record("expected the requested upstream to be usable")
        }
        #expect(sessionManager.sentToolRequests() == ["XcodeListNavigatorIssues@0"])
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
        #expect(sessionManager.requestSuccessNotificationCount() == 1)
        #expect(sessionManager.requestTimeoutNotificationCount() == 0)
    }

    @Test func forwardingServiceInternalToolUsesPreferredUpstreamWhenNoOverride()
        async throws
    {
        let config = makeHTTPConfig(requestTimeout: 0.2)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(eventLoopGroup) }
        let eventLoop = eventLoopGroup.next()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListNavigatorIssues")
                return .immediate(
                    try makeToolSuccessResponse(id: originalID, text: "{\"issues\":[]}")
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndices([1])
        sessionManager.setPreferredUpstreamIndex(0)

        let forwardingService = MCPForwardingService(
            configuration: config.runtime,
            sessionManager: sessionManager
        )

        let result = await forwardingService.callInternalTool(
            name: "XcodeListNavigatorIssues",
            arguments: ["tabIdentifier": "windowtab-1"],
            sessionID: "session-preferred",
            eventLoop: eventLoop
        )
        switch result {
        case .success:
            break
        case .cancelled:
            Issue.record("expected the preferred upstream dispatch to succeed")
        case .timeout:
            Issue.record("expected the preferred upstream dispatch to succeed")
        case .unavailable:
            Issue.record("expected the preferred upstream to be usable")
        }
        #expect(sessionManager.sentToolRequests() == ["XcodeListNavigatorIssues@0"])
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
        #expect(sessionManager.requestSuccessNotificationCount() == 1)
        #expect(sessionManager.requestTimeoutNotificationCount() == 0)
    }

    @Test func forwardingServiceInternalXcodeListWindowsUsesLiveWindowAggregation()
        async throws
    {
        let config = makeHTTPConfig(requestTimeout: 0.2)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(eventLoopGroup) }
        let eventLoop = eventLoopGroup.next()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListWindows")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "* tabIdentifier: tab-live, workspacePath: /Work/Live.xcworkspace"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndices([1])
        sessionManager.setToolRoutingDecision(.forward(preferredUpstreamIndex: 0))

        let forwardingService = MCPForwardingService(
            configuration: config.runtime,
            sessionManager: sessionManager
        )

        let result = await forwardingService.callInternalTool(
            name: "XcodeListWindows",
            arguments: [:],
            sessionID: "session-live-windows",
            eventLoop: eventLoop
        )

        switch result {
        case .success(let result):
            let content = try #require(result["content"] as? [[String: Any]])
            let text = try #require(content.first?["text"] as? String)
            #expect(text.contains("tab-live"))
        case .cancelled:
            Issue.record("expected live XcodeListWindows aggregation to succeed")
        case .timeout:
            Issue.record("expected live XcodeListWindows aggregation to succeed")
        case .unavailable:
            Issue.record("expected live XcodeListWindows aggregation to succeed")
        }

        #expect(sessionManager.sentToolRequests() == ["XcodeListWindows@1"])
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        #expect(sessionManager.assignedUpstreamIDCount() == 0)
    }

    @Test func httpRefreshCodeIssuesRequeuesLeaseAcrossRetryAttempts() async throws {
        var config = makeHTTPConfig(requestTimeout: 0)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .manual(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesClock: .testValue
        )
        let requestTask = Task {
            try await postHTTPData(
                url: server.url,
                sessionID: "session-retry-lease",
                payload: toolsCallPayload(
                    id: 14,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-lease",
                        "filePath": "App.swift",
                    ]
                )
            )
        }

        do {
            try await sessionManager.waitForSentUpstreamCount(2)
            #expect(sessionManager.requeuedLeaseCount() == 1)

            let inFlightLease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(inFlightLease.state == .active)
            #expect(inFlightLease.releaseReason == nil)
            #expect(inFlightLease.timeoutAt == nil)

            try await sessionManager.waitForPendingResponseCount(1)
            try sessionManager.deliverNextPendingResponse()

            let response = try await requestTask.value
            #expect(response.statusCode == 200)
            let body =
                (try? JSONSerialization.jsonObject(with: response.bodyData, options: []))
                as? [String: Any]
            let result = body?["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)

            let completedLease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(completedLease.state == .completed)
        } catch {
            requestTask.cancel()
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesCompletesLeaseWhenRetryBudgetExpires() async throws {
        var config = makeHTTPConfig(requestTimeout: 0.5)
        config.refreshCodeIssuesMode = .upstream
        let workflowUptimeClock = TestUptimeClock()
        let workflowClock = ClockClient(
            now: {
                Date(
                    timeIntervalSince1970:
                        Double(workflowUptimeClock.now()) / 1_000_000_000
                )
            },
            uptimeNanoseconds: workflowUptimeClock.now,
            sleep: { _ in },
            sleepForTimeInterval: { _ in }
        )
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                workflowUptimeClock.advance(by: .milliseconds(350))
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalID,
                        text:
                            "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesClock: workflowClock
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-retry-budget-exhausted",
                payload: toolsCallPayload(
                    id: 19,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-budget-exhausted",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
            #expect(sessionManager.requeuedLeaseCount() == 0)

            let lease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(lease.state == .completed)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpDirectRefreshSuccessDoesNotRecordLateLeaseResponse() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeRefreshCodeIssuesInFile")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "refresh-ok"
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
                sessionID: "session-direct-refresh-success",
                payload: toolsCallPayload(
                    id: 42,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-direct-success",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "refresh-ok")

            let lease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(lease.state == .completed)
            #expect(lease.lateResponseCount == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpDirectRefreshCancellationAbandonsActiveLease() async throws {
        var config = makeHTTPConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: nil,
            cancelAfterStartingEnqueueRequest: true
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-direct-refresh-cancelled",
                payload: toolsCallPayload(
                    id: 43,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-direct-cancelled",
                        "filePath": "App.swift",
                    ]
                )
            )
            #expect(response.statusCode == 202)
            #expect(body.isEmpty)
            #expect(sessionManager.sentUpstreamCount() == 1)

            let abandonedLease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(abandonedLease.state == .abandoned)
            #expect(abandonedLease.releaseReason == "clientDisconnected")
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }
}
