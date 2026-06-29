import Testing
import XcodeMCPKit
import XcodeMCPKitTesting

@Suite
struct XcodeMCPKitTestingTests {
    @Test func runtimeCreatesInitializedClientAndRecordsHandshake() async throws {
        let runtime = XcodeMCPTestRuntime()

        let client = try await runtime.makeClient(
                configuration: .init(
                clientName: "TestingClient",
                clientVersion: "1.0",
                capabilities: [
                    "roots": [:],
                    "experimental": [
                        "enabled": true,
                    ],
                ]
            )
        )
        await client.close()

        let messages = await runtime.recordedMessages()
        #expect(messages.map(\.method) == ["initialize", "notifications/initialized"])

        let initializeParams = try #require(messages.first?.params?.objectValue)
        #expect(initializeParams["clientInfo"] == [
            "name": "TestingClient",
            "version": "1.0",
        ])
        #expect(initializeParams["capabilities"] == [
            "experimental": [
                "enabled": true,
            ],
        ])
        #expect(await runtime.recordedCloseCount() == 1)
    }

    @Test func runtimeProvidesToolsAndToolResultsThroughPublicClientAPI() async throws {
        let runtime = XcodeMCPTestRuntime()
        await runtime.setTools([
            MCPTool(
                name: "DocumentationSearch",
                description: "Search docs",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                        ],
                    ],
                ]
            )
        ])
        await runtime.setToolResult(
            MCPToolResult(
                content: [
                    .text(
                        "Result for NavigationStack",
                        raw: [
                            "type": "text",
                            "text": "Result for NavigationStack",
                        ]
                    )
                ],
                structuredContent: [
                    "items": [
                        [
                            "title": "NavigationStack",
                        ],
                    ],
                ]
            ),
            forToolNamed: "DocumentationSearch"
        )

        let client = try await runtime.makeClient()
        defer {
            Task { await client.close() }
        }

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["DocumentationSearch"])

        let result = try await client.callTool(
            "DocumentationSearch",
            arguments: [
                "query": "NavigationStack",
            ]
        )

        #expect(result.structuredContent == [
            "items": [
                [
                    "title": "NavigationStack",
                ],
            ],
        ])
        guard case .text(let text, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text == "Result for NavigationStack")

        let toolCall = try #require(
            await runtime.recordedMessages().last { $0.method == "tools/call" }
        )
        #expect(toolCall.params?.objectValue?["arguments"] == [
            "query": "NavigationStack",
        ])
    }

    @Test func runtimeHandlesRawRequestsAndRecordsNotifications() async throws {
        let runtime = XcodeMCPTestRuntime()
        await runtime.setRequestHandler({ method, params in
            [
                "method": .string(method),
                "echo": params ?? .null,
            ]
        }, forMethod: "workspace/symbols")

        let client = try await runtime.makeClient()
        defer {
            Task { await client.close() }
        }

        let result = try await client.request(
            "workspace/symbols",
            params: [
                "query": "Observation",
            ]
        )
        try await client.notify(
            "notifications/custom",
            params: [
                "enabled": true,
            ]
        )

        #expect(result == [
            "method": "workspace/symbols",
            "echo": [
                "query": "Observation",
            ],
        ])

        let messages = await runtime.recordedMessages()
        let request = try #require(messages.last { $0.method == "workspace/symbols" })
        #expect(request.id != nil)
        #expect(request.params == [
            "query": "Observation",
        ])

        let notification = try #require(messages.last { $0.method == "notifications/custom" })
        #expect(notification.id == nil)
        #expect(notification.params == [
            "enabled": true,
        ])
    }

    @Test func runtimeRoutesProgressAndDynamicToolHandler() async throws {
        let runtime = XcodeMCPTestRuntime()
        await runtime.setProgressUpdates(
            [
                .init(progress: 0.25, total: 1, message: "Preparing"),
                .init(progress: 1, total: 1, message: "Done"),
            ],
            forToolNamed: "DocumentationSearch"
        )
        await runtime.setToolHandler { call in
            let text = "Result for \(call.arguments["query"]?.stringValue ?? "")"
            return MCPToolResult(
                content: [
                    .text(
                        text,
                        raw: [
                            "type": "text",
                            "text": .string(text),
                        ]
                    )
                ],
                structuredContent: [
                    "progressTokenWasPresent": .bool(call.progressToken != nil),
                ]
            )
        }

        let client = try await runtime.makeClient()
        defer {
            Task { await client.close() }
        }

        let progressValues = ProgressRecorder()
        let result = try await client.callTool(
            "DocumentationSearch",
            arguments: [
                "query": "Observation",
            ]
        ) { progress in
            await progressValues.append(progress)
        }

        #expect(result.structuredContent == [
            "progressTokenWasPresent": true,
        ])
        let progress = await progressValues.values
        #expect(progress.map(\.message) == ["Preparing", "Done"])
        #expect(progress.allSatisfy { $0.progressToken.isEmpty == false })
    }

    @Test func runtimeKeepsResponsesBoundToEachClient() async throws {
        let runtime = XcodeMCPTestRuntime()
        await runtime.setToolHandler { call in
            let query = call.arguments["query"]?.stringValue ?? ""
            return MCPToolResult(
                content: [
                    .text(
                        "Result for \(query)",
                        raw: [
                            "type": "text",
                            "text": .string("Result for \(query)"),
                        ]
                    )
                ],
                structuredContent: [
                    "query": .string(query),
                ]
            )
        }

        let config = XcodeMCPConfiguration(requestTimeout: .seconds(1))
        let firstClient = try await runtime.makeClient(configuration: config)
        let secondClient = try await runtime.makeClient(configuration: config)
        defer {
            Task {
                await firstClient.close()
                await secondClient.close()
            }
        }

        let secondResult = try await secondClient.callTool(
            "DocumentationSearch",
            arguments: [
                "query": "Second",
            ]
        )
        #expect(secondResult.structuredContent == [
            "query": "Second",
        ])

        let firstResult = try await firstClient.callTool(
            "DocumentationSearch",
            arguments: [
                "query": "First",
            ]
        )
        #expect(firstResult.structuredContent == [
            "query": "First",
        ])

        await firstClient.close()
        _ = try await secondClient.listTools()
        await secondClient.close()
        #expect(await runtime.recordedCloseCount() == 2)
    }

    @Test func runtimeTurnsServerErrorsIntoClientErrors() async throws {
        let runtime = XcodeMCPTestRuntime()
        await runtime.setToolHandler { _ in
            throw XcodeMCPTestRuntime.ServerError(
                code: -32042,
                message: "tool unavailable",
                data: [
                    "reason": "disabled",
                ]
            )
        }

        let client = try await runtime.makeClient()
        defer {
            Task { await client.close() }
        }

        await #expect(throws: XcodeMCPError.serverError(
            code: -32042,
            message: "tool unavailable",
            data: [
                "reason": "disabled",
            ]
        )) {
            _ = try await client.callTool("DocumentationSearch")
        }
    }
}

private actor ProgressRecorder {
    private(set) var values: [MCPProgress] = []

    func append(_ value: MCPProgress) {
        values.append(value)
    }
}
