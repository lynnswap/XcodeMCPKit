import Darwin
import Foundation
import NIO
import ProxyCore
import Testing

@testable import XcodeMCPProxy
@testable import ProxyXcodeSupport

@Suite(.serialized, .enabled(if: LiveMCPBridgeTestEnvironment.isEnabled))
struct LiveMCPBridgeTests {
    @Test(.enabled(if: DirectMCPBridgeTestEnvironment.isEnabled))
    func directMCPBridgeToolsListCanAutoApprovePermissionDialog() async throws {
        let xcrunResult = try runProcess("/usr/bin/xcrun", ["--find", "mcpbridge"])
        guard xcrunResult.terminationStatus == 0 else {
            Issue.record("mcpbridge is not available in the selected Xcode toolchain")
            throw LiveMCPBridgeTestError.mcpbridgeNotFound
        }
        let mcpbridgePath = xcrunResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mcpbridgePath.isEmpty == false else {
            Issue.record("xcrun --find mcpbridge returned an empty path")
            throw LiveMCPBridgeTestError.mcpbridgeNotFound
        }

        let session = try DirectMCPBridgeSession(executablePath: mcpbridgePath)
        defer { session.stop() }

        let assistantName = "XcodeMCPKitLiveDirectTest"
        let directMCPBridgeProcessID = session.processIdentifier
        let approver = XcodePermissionDialog.AutoApprover(
            dependencies: .live(
                agentPathCandidates: {
                    XcodePermissionDialog.AutoApprover.defaultAgentPathCandidates(
                        additionalExecutableCandidates: [mcpbridgePath]
                    )
                },
                assistantNameCandidates: {
                    ["XcodeMCPKit", assistantName]
                },
                serverProcessIDCandidates: {
                    XcodePermissionDialog.AutoApprover.defaultServerProcessIDCandidates()
                        .union([directMCPBridgeProcessID])
                }
            )
        )
        approver.start()
        defer { approver.stop() }

        let initialize = try session.request(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "clientInfo": [
                        "name": assistantName,
                        "version": "dev",
                    ],
                    "capabilities": [:],
                ],
            ],
            timeout: 20
        )
        #expect((initialize["result"] as? [String: Any])?["serverInfo"] != nil)

        try session.notify([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ])

        let tools = try session.request(
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
            ],
            timeout: 30
        )
        let toolList = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(toolList.isEmpty == false)
    }

    @Test func proxyServerTalksToLiveMCPBridge() async throws {
        let xcrunResult = try runProcess("/usr/bin/xcrun", ["--find", "mcpbridge"])
        guard xcrunResult.terminationStatus == 0,
              xcrunResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            Issue.record("mcpbridge is not available in the selected Xcode toolchain")
            throw LiveMCPBridgeTestError.mcpbridgeNotFound
        }

        let pgrepResult = try runProcess("/usr/bin/pgrep", ["-x", "Xcode"])
        guard pgrepResult.terminationStatus == 0 else {
            Issue.record("no running Xcode process found; open Xcode first")
            throw LiveMCPBridgeTestError.xcodeProcessNotFound
        }
        let xcodeProcessIDs = pgrepResult.stdout.split(whereSeparator: \.isNewline)
        guard xcodeProcessIDs.count == 1 else {
            Issue.record(
                "expected exactly one running Xcode process for auto-resolved mcpbridge, found \(xcodeProcessIDs.count)"
            )
            throw LiveMCPBridgeTestError.ambiguousXcodeProcessCount
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("xcode-mcp-live-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let discoveryFile = tempRoot.appendingPathComponent("endpoint.json")
        let defaultDiscoveryFile = ProxyFilesystemLocations.discoveryFileURL()
        let defaultDiscoveryBefore = try? Data(contentsOf: defaultDiscoveryFile)

        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: "/usr/bin/xcrun",
            upstreamArgs: ["mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 20,
            discoveryFileURL: discoveryFile,
            autoApproveXcodeDialog: true
        )
        var dependencies = ProxyServer.Dependencies.live(config: config)
        dependencies.discoveryClient = .live(
            defaultFileURL: { discoveryFile }
        )
        let server = ProxyServer(config: config, dependencies: dependencies)
        let urlSession = URLSession(configuration: .ephemeral)
        defer {
            urlSession.invalidateAndCancel()
        }

        do {
            let address = try server.startAndWriteDiscovery()
            let discoveryRecord = try readDiscoveryRecord(from: discoveryFile)
            #expect(discoveryRecord.port == address.port)

            let proxyURL = try #require(URL(string: discoveryRecord.url))
            let debugURL = try debugSnapshotURL(for: proxyURL)
            try await waitForServerReadiness(debugURL, urlSession: urlSession)

            let initializeResponse = try await postJSON(
                to: proxyURL,
                payload: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "protocolVersion": "2025-06-18",
                        "clientInfo": [
                            "name": "XcodeMCPKitLiveTest",
                            "version": "dev",
                        ],
                        "capabilities": [:],
                    ],
                ],
                sessionID: nil,
                urlSession: urlSession
            )
            let sessionID = try #require(
                initializeResponse.response.value(forHTTPHeaderField: "Mcp-Session-Id")
            )

            var debugBody = try await get(debugURL, urlSession: urlSession)

            var toolsBody = Data()
            var toolsListOK = false
            for _ in 0..<2 {
                let response = try await postJSON(
                    to: proxyURL,
                    payload: [
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/list",
                    ],
                    sessionID: sessionID,
                    urlSession: urlSession
                )
                toolsBody = response.body
                if bodyString(toolsBody).contains(#""name":"XcodeRefreshCodeIssuesInFile""#) {
                    toolsListOK = true
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }

            if !toolsListOK && !bodyString(toolsBody).contains(#""message":"upstream timeout""#) {
                debugBody = try await get(debugURL, urlSession: urlSession)
                Issue.record("tools/list did not expose XcodeRefreshCodeIssuesInFile: \(bodyString(toolsBody))")
                throw LiveMCPBridgeTestError.refreshToolNotFound
            }

            let windowSelection = try await resolveWindowSelection(
                proxyURL: proxyURL,
                sessionID: sessionID,
                urlSession: urlSession
            )
            let sourceFile = try #require(firstSwiftSourceFile(under: searchRoot(for: windowSelection.workspacePath)))

            let refreshResponse = try await postJSON(
                to: proxyURL,
                payload: [
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": [
                        "name": "XcodeRefreshCodeIssuesInFile",
                        "arguments": [
                            "filePath": sourceFile.path,
                            "tabIdentifier": windowSelection.tabIdentifier,
                        ],
                    ],
                ],
                sessionID: sessionID,
                urlSession: urlSession
            )
            #expect(bodyString(refreshResponse.body).contains(#""result""#) || bodyString(refreshResponse.body).contains(#""error""#))

            debugBody = try await get(debugURL, urlSession: urlSession)
            #expect(bodyString(debugBody).contains(#""controlPlane""#))

            let defaultDiscoveryAfter = try? Data(contentsOf: defaultDiscoveryFile)
            #expect(defaultDiscoveryBefore == defaultDiscoveryAfter)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}

private enum LiveMCPBridgeTestEnvironment {
    static let isEnabled =
        ProcessInfo.processInfo.environment["XCODE_MCP_RUN_LIVE_MCPBRIDGE_TESTS"] == "1"
}

private enum DirectMCPBridgeTestEnvironment {
    static let isEnabled =
        ProcessInfo.processInfo.environment["XCODE_MCP_RUN_DIRECT_MCPBRIDGE_TESTS"] == "1"
}

private struct CommandResult {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}

private func runProcess(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return CommandResult(
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        terminationStatus: process.terminationStatus
    )
}

private func readDiscoveryRecord(from fileURL: URL) throws -> DiscoveryRecord {
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DiscoveryRecord.self, from: data)
}

private func debugSnapshotURL(for proxyURL: URL) throws -> URL {
    var components = try #require(URLComponents(url: proxyURL, resolvingAgainstBaseURL: false))
    components.path = "/debug/upstreams"
    components.query = nil
    return try #require(components.url)
}

private func waitForServerReadiness(_ debugURL: URL, urlSession: URLSession) async throws {
    var lastError: Error?
    for _ in 0..<50 {
        do {
            _ = try await get(debugURL, timeoutInterval: 1, urlSession: urlSession)
            return
        } catch {
            lastError = error
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    Issue.record("proxy HTTP listener was not reachable: \(String(describing: lastError))")
    throw LiveMCPBridgeTestError.httpServerNotReady
}

private func postJSON(
    to url: URL,
    payload: [String: Any],
    sessionID: String?,
    urlSession: URLSession
) async throws -> (body: Data, response: HTTPURLResponse) {
    var request = URLRequest(url: url, timeoutInterval: 25)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await urlSession.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

private func get(
    _ url: URL,
    timeoutInterval: TimeInterval = 10,
    urlSession: URLSession
) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    let (data, response) = try await urlSession.data(for: request)
    _ = try #require(response as? HTTPURLResponse)
    return data
}

private func bodyString(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
}

private func resolveWindowSelection(
    proxyURL: URL,
    sessionID: String,
    urlSession: URLSession
) async throws -> (tabIdentifier: String, workspacePath: String) {
    for _ in 0..<2 {
        let response = try await postJSON(
            to: proxyURL,
            payload: [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": [
                    "name": "XcodeListWindows",
                    "arguments": [:],
                ],
            ],
            sessionID: sessionID,
            urlSession: urlSession
        )
        if let selection = try windowSelection(from: response.body) {
            return selection
        }
        try await Task.sleep(for: .seconds(1))
    }

    Issue.record("failed to resolve an open Xcode workspace from XcodeListWindows")
    throw LiveMCPBridgeTestError.windowSelectionNotFound
}

private func windowSelection(from data: Data) throws -> (tabIdentifier: String, workspacePath: String)? {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let result = object?["result"] as? [String: Any] ?? [:]
    let structured = result["structuredContent"] as? [String: Any]
    let structuredMessage = structured?["message"] as? String
    let content = result["content"] as? [[String: Any]] ?? []
    let contentMessage = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    let message = structuredMessage?.isEmpty == false ? structuredMessage ?? "" : contentMessage

    for line in message.split(separator: "\n") {
        let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("* tabIdentifier: ") else { continue }
        let suffix = raw.dropFirst("* tabIdentifier: ".count)
        guard let comma = suffix.range(of: ", workspacePath: ") else { continue }
        let tabIdentifier = String(suffix[..<comma.lowerBound])
        let workspacePath = String(suffix[comma.upperBound...])
        if !workspacePath.isEmpty {
            return (tabIdentifier, workspacePath)
        }
    }

    return nil
}

private func searchRoot(for workspacePath: String) -> URL {
    let workspaceURL = URL(fileURLWithPath: workspacePath)
    if ["xcworkspace", "xcodeproj"].contains(workspaceURL.pathExtension.lowercased()) {
        return workspaceURL.deletingLastPathComponent()
    }
    return workspaceURL
}

private func firstSwiftSourceFile(under root: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        return nil
    }

    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        guard !url.path.contains("/.build/") else { continue }
        return url
    }
    return nil
}

private enum LiveMCPBridgeTestError: Error {
    case mcpbridgeNotFound
    case xcodeProcessNotFound
    case ambiguousXcodeProcessCount
    case httpServerNotReady
    case refreshToolNotFound
    case windowSelectionNotFound
    case directMCPBridgeResponseTimedOut
    case directMCPBridgeTerminated(String)
    case directMCPBridgeInvalidResponse
}

private final class DirectMCPBridgeSession {
    let processIdentifier: pid_t

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(executablePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        self.processIdentifier = process.processIdentifier
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading

        setNonBlocking(stdout.fileDescriptor)
        setNonBlocking(stderr.fileDescriptor)
    }

    func request(_ object: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        try send(object)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                throw LiveMCPBridgeTestError.directMCPBridgeTerminated(stderrText())
            }
            drain(stderr, into: &stderrBuffer)
            drain(stdout, into: &stdoutBuffer)
            if let line = nextStdoutLine() {
                guard let data = line.data(using: .utf8),
                      let response = try JSONSerialization.jsonObject(with: data, options: [])
                        as? [String: Any] else {
                    throw LiveMCPBridgeTestError.directMCPBridgeInvalidResponse
                }
                return response
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw LiveMCPBridgeTestError.directMCPBridgeResponseTimedOut
    }

    func notify(_ object: [String: Any]) throws {
        try send(object)
    }

    func stop() {
        try? stdin.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try? stdout.close()
        try? stderr.close()
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try stdin.write(contentsOf: data + Data([0x0A]))
    }

    private func nextStdoutLine() -> String? {
        guard let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) else {
            return nil
        }
        let lineData = stdoutBuffer[..<newlineIndex]
        stdoutBuffer.removeSubrange(...newlineIndex)
        return String(data: lineData, encoding: .utf8)
    }

    private func stderrText() -> String {
        drain(stderr, into: &stderrBuffer)
        return String(data: stderrBuffer, encoding: .utf8) ?? ""
    }

    private func drain(_ handle: FileHandle, into buffer: inout Data) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = unsafe Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }

    private func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }
}
