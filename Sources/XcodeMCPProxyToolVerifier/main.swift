import Foundation
import XcodeMCPKit

@main
struct XcodeMCPProxyToolVerifier {
    static func main() async {
        do {
            let options = try VerifierOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let runner = ProxyToolVerifier(options: options)
            let hasFailures = try await runner.run()
            Foundation.exit(hasFailures ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data("error: \(errorDescription(error))\n".utf8))
            Foundation.exit(1)
        }
    }
}

private struct VerifierOptions {
    var host = "127.0.0.1"
    var port = 18_765
    var upstreamProcesses = 2
    var requestTimeoutSeconds = 600
    var outputDirectory = URL(fileURLWithPath: "ProxyToolVerifierOutput", isDirectory: true)
    var keepServer = false
    var noOpenXcode = false
    var verbose = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host":
                host = try Self.value(after: argument, in: arguments, index: &index)
            case "--port":
                port = try Int(Self.value(after: argument, in: arguments, index: &index))
                    ?? Self.fail("--port requires an integer")
            case "--upstream-processes":
                upstreamProcesses = try Int(Self.value(after: argument, in: arguments, index: &index))
                    ?? Self.fail("--upstream-processes requires an integer")
            case "--request-timeout":
                requestTimeoutSeconds = try Int(Self.value(after: argument, in: arguments, index: &index))
                    ?? Self.fail("--request-timeout requires an integer")
            case "--output":
                outputDirectory = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, index: &index), isDirectory: true)
            case "--keep-server":
                keepServer = true
            case "--no-open-xcode":
                noOpenXcode = true
            case "-v", "--verbose":
                verbose = true
            case "-h", "--help":
                print(Self.usage)
                Foundation.exit(0)
            default:
                throw VerifierFailure("unknown argument: \(argument)")
            }
            index += 1
        }
    }

    var endpoint: URL {
        URL(string: "http://\(host):\(port)/mcp")!
    }

    static let usage = """
    Usage:
      swift run xcode-mcp-proxy-tool-verifier [options]

    Options:
      --host host                 Listen host for the debug proxy server. Default: 127.0.0.1
      --port port                 Dedicated verifier port. Default: 18765
      --upstream-processes n      Upstream mcpbridge processes per Xcode. Default: 2
      --request-timeout seconds   XcodeMCP request timeout. Default: 600
      --output path               Ignored verifier output directory. Default: ProxyToolVerifierOutput
      --keep-server               Leave the debug proxy server running.
      --no-open-xcode             Do not open the fixture package in Xcode.
      -v, --verbose               Print tool arguments and response summaries.
    """

    private static func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw VerifierFailure("\(flag) requires a value")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func fail<T>(_ message: String) throws -> T {
        throw VerifierFailure(message)
    }
}

private struct ProxyToolVerifier {
    let options: VerifierOptions
    let fileManager = FileManager.default

    func run() async throws -> Bool {
        let repoRoot = try repositoryRoot()
        let outputRoot = absoluteURL(options.outputDirectory, relativeTo: repoRoot)
        let fixture = FixtureLayout(repoRoot: repoRoot, outputRoot: outputRoot)

        try prepareOutputDirectory(outputRoot)
        try prepareFixture(fixture)
        let fixtureSnapshot = try FixtureSnapshot.capture(fixture)
        defer {
            try? fixtureSnapshot.restore()
        }

        if options.noOpenXcode == false {
            try openFixtureInXcode(fixture.rootWorkspaceURL)
        }

        try buildDebugProxyServer(in: repoRoot)
        let server = try startDebugProxyServer(repoRoot: repoRoot, outputRoot: outputRoot)
        defer {
            if options.keepServer == false {
                server.terminate()
            }
        }

        let client = try await connectToProxy()
        defer {
            Task {
                await client.close()
            }
        }

        var state = VerificationState(fixture: fixture)
        let tools = try await client.listTools()
        state.availableTools = Set(tools.map(\.name))
        var records: [ToolVerificationRecord] = []
        let reportURL = outputRoot.appendingPathComponent("report.json")

        func currentReport() -> VerificationReport {
            VerificationReport(
                endpoint: options.endpoint.absoluteString,
                fixturePath: fixture.xcodeProjectURL.path,
                workspacePath: fixture.rootWorkspaceURL.path,
                toolCount: tools.count,
                availableTools: tools.map(\.name).sorted(),
                toolDescriptors: tools.sorted { $0.name < $1.name },
                records: records
            )
        }

        let executionPlan = toolExecutionOrder(availableTools: state.availableTools)
        print("Available tools: \(tools.count)")
        print("Planned tools: \(executionPlan.count)")

        for (index, toolName) in executionPlan.enumerated() {
            guard state.availableTools.contains(toolName) else {
                records.append(
                    ToolVerificationRecord(
                        name: toolName,
                        status: .failed,
                        elapsedSeconds: 0,
                        detail: "missing from tools/list",
                        arguments: nil
                    )
                )
                continue
            }
            let arguments = state.arguments(for: toolName)
            print("-> [\(index + 1)/\(executionPlan.count)] \(toolName)")
            let record = await call(
                toolName,
                arguments: arguments,
                client: client
            )
            print("<- [\(record.status.rawValue)] \(toolName) (\(formatSeconds(record.elapsedSeconds)))")
            records.append(record)
            state.observe(toolName: toolName, record: record)
            try writeReport(currentReport(), to: reportURL, announce: false)
        }

        let report = currentReport()
        try writeReport(report, to: reportURL)
        printReport(report)
        return report.hasHardFailures
    }

    private func call(
        _ toolName: String,
        arguments: [String: MCPJSONValue],
        client: XcodeMCP
    ) async -> ToolVerificationRecord {
        let started = Date()
        do {
            let result = try await client.callTool(toolName, arguments: arguments)
            let elapsed = Date().timeIntervalSince(started)
            let detail = responseSummary(result)
            let status = verificationStatus(
                toolName: toolName,
                result: result,
                detail: detail
            )
            return ToolVerificationRecord(
                name: toolName,
                status: status,
                elapsedSeconds: elapsed,
                detail: detail,
                arguments: arguments,
                rawResult: result.raw
            )
        } catch let error as XcodeMCPError {
            let elapsed = Date().timeIntervalSince(started)
            let status: ToolVerificationStatus
            switch error {
            case .requestTimedOut:
                status = .hung
            case .serverError:
                status = .rpcError
            case .closed, .invalidRequest, .invalidResponse, .transportUnavailable:
                status = .failed
            }
            return ToolVerificationRecord(
                name: toolName,
                status: status,
                elapsedSeconds: elapsed,
                detail: errorDescription(error),
                arguments: arguments
            )
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            return ToolVerificationRecord(
                name: toolName,
                status: .failed,
                elapsedSeconds: elapsed,
                detail: errorDescription(error),
                arguments: arguments
            )
        }
    }

    private func connectToProxy() async throws -> XcodeMCP {
        var lastError: (any Error)?
        for _ in 0..<90 {
            do {
                return try await XcodeMCP(
                    config: .init(
                        transport: .streamableHTTP(endpoint: options.endpoint),
                        clientName: "XcodeMCPProxyToolVerifier",
                        clientVersion: "dev",
                        requestTimeout: .seconds(options.requestTimeoutSeconds)
                    )
                )
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw VerifierFailure(
            "proxy did not become ready at \(options.endpoint.absoluteString): \(lastError.map(errorDescription) ?? "unknown error")"
        )
    }

    private func prepareOutputDirectory(_ outputRoot: URL) throws {
        try fileManager.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true
        )
    }

    private func prepareFixture(_ fixture: FixtureLayout) throws {
        guard fileManager.fileExists(atPath: fixture.xcodeProjectURL.path) else {
            throw VerifierFailure("missing tracked verifier fixture at \(fixture.xcodeProjectURL.path)")
        }
        try? fileManager.removeItem(at: fixture.scratchDirectoryURL)
    }

    private func buildDebugProxyServer(in repoRoot: URL) throws {
        print("Building debug xcode-mcp-proxy-server...")
        try runProcess(
            executable: "/usr/bin/swift",
            arguments: ["build", "--configuration", "debug", "--product", "xcode-mcp-proxy-server"],
            currentDirectory: repoRoot
        )
    }

    private func startDebugProxyServer(repoRoot: URL, outputRoot: URL) throws -> RunningProcess {
        let binary = repoRoot.appendingPathComponent(".build/debug/xcode-mcp-proxy-server")
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw VerifierFailure("debug proxy server binary is missing: \(binary.path)")
        }
        let logURL = outputRoot.appendingPathComponent("proxy-server.log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--listen", "\(options.host):\(options.port)",
            "--upstream-processes", "\(options.upstreamProcesses)",
            "--auto-approve",
            "--refresh-code-issues-mode", "proxy",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["XCODE_MCP_PROXY_CACHE_ROOT"] = outputRoot.appendingPathComponent("cache").path
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        print("Started debug proxy server: \(options.endpoint.absoluteString)")
        print("Proxy log: \(logURL.path)")
        return RunningProcess(process: process, logHandle: logHandle)
    }

    private func openFixtureInXcode(_ projectURL: URL) throws {
        if fileManager.isExecutableFile(atPath: "/usr/bin/xed") {
            try runProcess(
                executable: "/usr/bin/xed",
                arguments: ["-b", projectURL.path],
                currentDirectory: projectURL.deletingLastPathComponent()
            )
        } else {
            try runProcess(
                executable: "/usr/bin/open",
                arguments: ["-a", "Xcode", projectURL.path],
                currentDirectory: projectURL.deletingLastPathComponent()
            )
        }
    }

    private func repositoryRoot() throws -> URL {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        if fileManager.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd
        }
        throw VerifierFailure("run from the XcodeMCPKit repository root")
    }

    private func absoluteURL(_ url: URL, relativeTo base: URL) -> URL {
        if url.path.hasPrefix("/") {
            return url
        }
        return base.appendingPathComponent(url.path)
    }

    private func writeReport(_ report: VerificationReport, to url: URL, announce: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url)
        if announce {
            print("Report: \(url.path)")
        }
    }

    private func printReport(_ report: VerificationReport) {
        let counts = Dictionary(grouping: report.records, by: \.status)
            .mapValues(\.count)
        print("")
        print("Summary")
        for status in ToolVerificationStatus.allCases {
            print("  \(status.rawValue): \(counts[status, default: 0])")
        }
        print("")
        print("Tools")
        for record in report.records {
            let elapsed = formatSeconds(record.elapsedSeconds)
            print("  [\(record.status.rawValue)] \(record.name) (\(elapsed)) - \(record.detail)")
            if options.verbose, let arguments = record.arguments {
                print("    args: \(jsonString(arguments))")
            }
        }
        let testedTools = report.records
            .map(\.name)
            .filter { $0 != "tools/list" }
        print("")
        print("Tested tools (\(testedTools.count))")
        for name in testedTools.sorted() {
            print("  - \(name)")
        }
    }
}

private struct VerificationState {
    let fixture: FixtureLayout
    var availableTools: Set<String> = []
    var tabIdentifier = "windowtab1"
    var schemeName = "ProxyToolVerifierFixture"
    var runDestination = "iPhone 17 (27.0)"
    var testTargetName = "ProxyToolVerifierFixtureTests"
    var testIdentifier = "ProxyToolVerifierFixtureTests/testMessage()"
    var interactionSessionIdentifier = "Proxy Tool Verifier \(UUID().uuidString)"
    var interactionSessionKey = "invalid-verifier-session-key"

    var navigatorRoot: String {
        "ProxyToolVerifierFixture"
    }

    func navPath(_ path: String) -> String {
        "\(navigatorRoot)/\(path)"
    }

    func arguments(for toolName: String) -> [String: MCPJSONValue] {
        switch toolName {
        case "BuildProject":
            return ["tabIdentifier": .string(tabIdentifier), "buildForTesting": .bool(true)]
        case "DeviceInteractionEndSession":
            return ["interactionSessionKey": .string(interactionSessionKey)]
        case "DeviceInteractionInstallAndRun":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "interactionSessionKey": .string(interactionSessionKey),
            ]
        case "DeviceInteractionStartSession":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "sessionIdentifier": .string(interactionSessionIdentifier),
            ]
        case "DeviceInteractionSynthesize":
            return [
                "interactSessionKey": .string(interactionSessionKey),
            ]
        case "DocumentationSearch":
            return ["query": .string("NavigationStack")]
        case "GetBuildLog":
            return ["tabIdentifier": .string(tabIdentifier), "severity": .string("remark")]
        case "GetConsoleOutput":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "outputType": .string("all"),
                "tailLimit": .integer(100),
            ]
        case "GetCrashIssueLogs":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "signature_name": .string("ProxyVerifierCrashSignature"),
                "bundle_id": .string("dev.xcodemcp.ProxyToolVerifierFixture"),
                "platform": .string("macOS"),
                "app_version": .string("1.0"),
            ]
        case "GetFieldPerformanceIssueLogs":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "app_version": .string("1.0"),
                "signature_name": .string("ProxyVerifierPerformanceSignature"),
                "diagnostic_type": .string("hangs"),
                "bundle_id": .string("dev.xcodemcp.ProxyToolVerifierFixture"),
                "platform": .string("macOS"),
            ]
        case "GetFileCompilerFlags":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "targetName": .string("ProxyToolVerifierFixture"),
                "filePath": .string(navPath("VerifierCore.swift")),
            ]
        case "GetTestList":
            return ["tabIdentifier": .string(tabIdentifier)]
        case "GetTopCrashIssues":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "count": .integer(1),
                "bundle_id": .string("dev.xcodemcp.ProxyToolVerifierFixture"),
                "platform": .string("macOS"),
            ]
        case "GetTopFieldPerformanceIssues":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "diagnostic_type": .string("hangs"),
                "bundle_id": .string("dev.xcodemcp.ProxyToolVerifierFixture"),
                "platform": .string("macOS"),
            ]
        case "InvokeDebuggerCommand":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "command": .string("thread list"),
                "timeout": .integer(20),
            ]
        case "LocalizationPlanner":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "targetLocaleIdentifier": .string("ja"),
            ]
        case "RenderPreview":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "sourceFilePath": .string(navPath("ContentView.swift")),
                "timeout": .integer(180),
            ]
        case "RunAllTests":
            return ["tabIdentifier": .string(tabIdentifier)]
        case "RunCodeSnippet":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "sourceFilePath": .string(navPath("VerifierCore.swift")),
                "purpose": .string("Proxy verifier snippet"),
                "codeSnippet": .string(#"print(VerifierCore.message())"#),
                "timeout": .integer(120),
            ]
        case "RunProject":
            return ["tabIdentifier": .string(tabIdentifier), "attachDebugger": .bool(true)]
        case "RunSomeTests":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "tests": .array([
                    .object([
                        "targetName": .string(testTargetName),
                        "testIdentifier": .string(testIdentifier),
                    ])
                ]),
            ]
        case "StopProject":
            return ["tabIdentifier": .string(tabIdentifier)]
        case "StringCatalogContext":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("Localizable.xcstrings")),
                "stringKey": .string("verifier.title"),
                "targetLocaleIdentifier": .string("ja"),
            ]
        case "StringCatalogEdit":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("Localizable.xcstrings")),
                "stringKey": .string("verifier.title"),
                "targetLocaleIdentifier": .string("ja"),
                "translation": .string("Verifier Title JA Updated"),
            ]
        case "StringCatalogRead":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("Localizable.xcstrings")),
                "targetLocaleIdentifier": .string("ja"),
                "keyLimit": .integer(20),
            ]
        case "UpdateFileCompilerFlags":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "targetName": .string("ProxyToolVerifierFixture"),
                "filePath": .string(navPath("VerifierCore.swift")),
                "compilerFlags": .string("-DPROXY_TOOL_VERIFIER"),
                "appendValue": .bool(false),
            ]
        case "XcodeGetCurrentFile":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "includeContent": .bool(false),
                "includeSelection": .bool(true),
            ]
        case "XcodeGlob":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "pattern": .string("**/*.swift"),
            ]
        case "XcodeGrep":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "pattern": .string("VerifierCore"),
                "outputMode": .string("filesWithMatches"),
                "headLimit": .integer(10),
            ]
        case "XcodeListNavigatorIssues":
            return ["tabIdentifier": .string(tabIdentifier), "severity": .string("remark")]
        case "XcodeListRunDestinations":
            return ["tabIdentifier": .string(tabIdentifier), "includeIncompatible": .bool(true)]
        case "XcodeListSchemes":
            return ["tabIdentifier": .string(tabIdentifier)]
        case "XcodeListWindows":
            return [:]
        case "XcodeLS":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "path": .string(navigatorRoot),
                "recursive": .bool(true),
            ]
        case "XcodeMakeDir":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "directoryPath": .string(navPath("VerifierScratch")),
            ]
        case "XcodeMV":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "sourcePath": .string(navPath("VerifierScratch/probe.txt")),
                "destinationPath": .string(navPath("VerifierScratch/probe-moved.txt")),
                "operation": .object(["rawValue": .string("move")]),
                "overwriteExisting": .bool(true),
            ]
        case "XcodeRead":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("VerifierCore.swift")),
                "limit": .integer(40),
            ]
        case "XcodeRefreshCodeIssuesInFile":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("VerifierCore.swift")),
            ]
        case "XcodeRM":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "path": .string(navPath("VerifierScratch/probe-moved.txt")),
                "recursive": .bool(false),
                "deleteFiles": .bool(true),
            ]
        case "XcodeSwitchRunDestination":
            return ["tabIdentifier": .string(tabIdentifier), "displayTitle": .string(runDestination)]
        case "XcodeSwitchScheme":
            return ["tabIdentifier": .string(tabIdentifier), "schemeName": .string(schemeName)]
        case "XcodeUpdate":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("VerifierScratch/probe.txt")),
                "oldString": .string("initial"),
                "newString": .string("updated"),
                "replaceAll": .bool(false),
            ]
        case "XcodeWrite":
            return [
                "tabIdentifier": .string(tabIdentifier),
                "filePath": .string(navPath("VerifierScratch/probe.txt")),
                "content": .string("proxy verifier initial content\n"),
            ]
        default:
            return [:]
        }
    }

    mutating func observe(toolName: String, record: ToolVerificationRecord) {
        guard let rawResult = record.rawResult else { return }
        switch toolName {
        case "XcodeListWindows":
            if let parsed = parseWindowTab(
                from: rawResult,
                fixturePaths: [
                    fixture.rootWorkspaceURL.path,
                ],
                fallbackWorkspaceName: "XcodeMCPKit.xcworkspace"
            ) {
                tabIdentifier = parsed
            }
        case "XcodeListSchemes":
            if flattenedText(from: rawResult).contains(schemeName) {
                break
            }
            if let parsed = parseFirstString(named: "schemeName", from: rawResult)
                ?? parseFirstString(named: "name", from: rawResult) {
                schemeName = parsed
            }
        case "XcodeListRunDestinations":
            if let parsed = parsePreferredRunDestination(from: rawResult)
                ?? parseFirstString(named: "activeDestinationDisplayTitle", from: rawResult)
                ?? parseFirstString(named: "displayTitle", from: rawResult) {
                runDestination = parsed
            }
        case "GetTestList":
            if let test = parseFirstTest(from: rawResult) {
                testTargetName = test.targetName
                testIdentifier = test.identifier
            }
        case "DeviceInteractionStartSession":
            if let key = parseFirstString(named: "interactionSessionKey", from: rawResult)
                ?? parseFirstString(named: "interactSessionKey", from: rawResult)
                ?? parseFirstString(named: "sessionKey", from: rawResult) {
                interactionSessionKey = key
            }
        default:
            break
        }
    }
}

private struct FixtureLayout {
    let repoRoot: URL
    let outputRoot: URL

    var rootWorkspaceURL: URL {
        repoRoot.appendingPathComponent("XcodeMCPKit.xcworkspace", isDirectory: true)
    }

    var projectRootURL: URL {
        repoRoot.appendingPathComponent("Fixtures/ProxyToolVerifierFixture", isDirectory: true)
    }

    var xcodeProjectURL: URL {
        projectRootURL.appendingPathComponent("ProxyToolVerifierFixture.xcodeproj", isDirectory: true)
    }

    var scratchDirectoryURL: URL {
        projectRootURL.appendingPathComponent("ProxyToolVerifierFixture/VerifierScratch", isDirectory: true)
    }

    var projectFileURL: URL {
        xcodeProjectURL.appendingPathComponent("project.pbxproj")
    }

    var localizableCatalogURL: URL {
        projectRootURL.appendingPathComponent("ProxyToolVerifierFixture/Localizable.xcstrings")
    }

    var infoPlistCatalogURL: URL {
        projectRootURL.appendingPathComponent("ProxyToolVerifierFixture/ProxyToolVerifierFixture-InfoPlist.xcstrings")
    }
}

private struct FixtureSnapshot {
    let scratchDirectoryURL: URL
    let files: [(url: URL, data: Data)]

    static func capture(_ fixture: FixtureLayout) throws -> FixtureSnapshot {
        try FixtureSnapshot(
            scratchDirectoryURL: fixture.scratchDirectoryURL,
            files: [
                fixture.projectFileURL,
                fixture.localizableCatalogURL,
                fixture.infoPlistCatalogURL,
            ].map { url in
                (url: url, data: try Data(contentsOf: url))
            }
        )
    }

    func restore() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: scratchDirectoryURL)
        for file in files {
            try fileManager.createDirectory(
                at: file.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: file.url, options: [.atomic])
        }
    }
}

private final class RunningProcess {
    private let process: Process
    private let logHandle: FileHandle

    init(process: Process, logHandle: FileHandle) {
        self.process = process
        self.logHandle = logHandle
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? logHandle.close()
    }
}

private struct VerificationReport: Codable {
    let endpoint: String
    let fixturePath: String
    let workspacePath: String
    let toolCount: Int
    let availableTools: [String]
    let toolDescriptors: [MCPTool]
    let records: [ToolVerificationRecord]

    var hasHardFailures: Bool {
        records.contains { $0.status.isHardFailure }
    }
}

private struct ToolVerificationRecord: Codable {
    let name: String
    let status: ToolVerificationStatus
    let elapsedSeconds: TimeInterval
    let detail: String
    let arguments: [String: MCPJSONValue]?
    let rawResult: MCPJSONValue?

    init(
        name: String,
        status: ToolVerificationStatus,
        elapsedSeconds: TimeInterval,
        detail: String,
        arguments: [String: MCPJSONValue]?,
        rawResult: MCPJSONValue? = nil
    ) {
        self.name = name
        self.status = status
        self.elapsedSeconds = elapsedSeconds
        self.detail = detail
        self.arguments = arguments
        self.rawResult = rawResult
    }
}

private enum ToolVerificationStatus: String, Codable, CaseIterable {
    case passed
    case externalPrerequisite
    case toolError
    case rpcError
    case failed
    case hung

    var isHardFailure: Bool {
        switch self {
        case .passed, .externalPrerequisite:
            return false
        case .toolError, .rpcError, .failed, .hung:
            return true
        }
    }
}

private func verificationStatus(
    toolName: String,
    result: MCPToolResult,
    detail: String
) -> ToolVerificationStatus {
    if isExternalPrerequisiteResult(toolName: toolName, detail: detail) {
        return .externalPrerequisite
    }
    if result.isError {
        return .toolError
    }
    if detail.hasPrefix("Failed ") || detail.contains(#""type":"error""#) {
        return .toolError
    }
    return .passed
}

private func isExternalPrerequisiteResult(toolName: String, detail: String) -> Bool {
    let appStoreConnectTools: Set<String> = [
        "GetTopCrashIssues",
        "GetCrashIssueLogs",
        "GetTopFieldPerformanceIssues",
        "GetFieldPerformanceIssueLogs",
    ]
    if appStoreConnectTools.contains(toolName) {
        return detail.contains("Product not found")
            || detail.contains("not a supported platform")
            || detail.contains("App Store")
            || detail.contains("Organizer")
    }

    let deviceTools: Set<String> = [
        "DeviceInteractionStartSession",
        "DeviceInteractionInstallAndRun",
        "DeviceInteractionSynthesize",
        "DeviceInteractionEndSession",
    ]
    if deviceTools.contains(toolName) {
        return detail.contains("not supported for Device Interaction")
            || detail.contains("Session key is invalid")
            || detail.contains("Session not found")
    }

    return false
}

private func toolExecutionOrder(availableTools: Set<String>) -> [String] {
    let known = orderedKnownToolNames()
    let plannedKnown = known.filter { availableTools.contains($0) }
    let unknown = availableTools.subtracting(Set(known)).sorted()
    return plannedKnown + unknown
}

private func orderedKnownToolNames() -> [String] {
    deduplicated(
        catalogToolNames()
            + bootstrapToolNames()
            + navigatorToolNames()
            + stringCatalogToolNames()
            + buildToolNames()
            + runtimeToolNames()
            + fieldReportToolNames()
            + deviceInteractionToolNames()
    )
}

private func catalogToolNames() -> [String] {
    [
        "XcodeListWindows",
        "XcodeListSchemes",
        "XcodeListRunDestinations",
        "DocumentationSearch",
    ]
}

private func bootstrapToolNames() -> [String] {
    [
        "XcodeListWindows",
        "XcodeListSchemes",
        "XcodeListRunDestinations",
        "XcodeSwitchScheme",
        "XcodeSwitchRunDestination",
    ]
}

private func navigatorToolNames() -> [String] {
    [
        "XcodeGlob",
        "XcodeLS",
        "XcodeRead",
        "XcodeGrep",
        "XcodeGetCurrentFile",
        "XcodeMakeDir",
        "XcodeWrite",
        "XcodeUpdate",
        "XcodeMV",
        "XcodeRM",
        "GetFileCompilerFlags",
        "UpdateFileCompilerFlags",
        "XcodeRefreshCodeIssuesInFile",
        "XcodeListNavigatorIssues",
    ]
}

private func stringCatalogToolNames() -> [String] {
    [
        "StringCatalogRead",
        "StringCatalogContext",
        "StringCatalogEdit",
        "LocalizationPlanner",
    ]
}

private func buildToolNames() -> [String] {
    [
        "BuildProject",
        "GetBuildLog",
        "GetTestList",
        "RunSomeTests",
        "RunAllTests",
    ]
}

private func runtimeToolNames() -> [String] {
    [
        "RenderPreview",
        "RunCodeSnippet",
        "RunProject",
        "GetConsoleOutput",
        "InvokeDebuggerCommand",
        "StopProject",
    ]
}

private func fieldReportToolNames() -> [String] {
    [
        "GetTopCrashIssues",
        "GetCrashIssueLogs",
        "GetTopFieldPerformanceIssues",
        "GetFieldPerformanceIssueLogs",
    ]
}

private func deviceInteractionToolNames() -> [String] {
    [
        "DeviceInteractionStartSession",
        "DeviceInteractionInstallAndRun",
        "DeviceInteractionSynthesize",
        "DeviceInteractionEndSession",
    ]
}

private func deduplicated(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

private func responseSummary(_ result: MCPToolResult) -> String {
    let text = textContent(from: result)
    if text.isEmpty == false {
        return abbreviate(text.replacingOccurrences(of: "\n", with: " "), limit: 240)
    }
    if let structured = result.structuredContent {
        return abbreviate(jsonString(structured), limit: 240)
    }
    return result.isError ? "tool returned isError=true" : "ok"
}

private func textContent(from result: MCPToolResult) -> String {
    result.content.compactMap { item -> String? in
        switch item {
        case .text(let text, _):
            if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let message = object["message"] as? String {
                return message
            }
            return text
        case .resource(_, let text, _, _):
            return text
        case .image, .raw:
            return nil
        }
    }
    .joined(separator: "\n")
}

private func parseWindowTab(
    from value: MCPJSONValue,
    fixturePaths: [String],
    fallbackWorkspaceName: String
) -> String? {
    let normalizedFixturePaths = fixturePaths.map(normalizePath)
    var fallbackTab: String?
    for text in allStrings(from: value) {
        for line in text.split(whereSeparator: \.isNewline) {
            let lineText = String(line)
            guard let tab = extractValue(after: "tabIdentifier:", before: ",", in: lineText),
                  let workspace = extractValue(after: "workspacePath:", before: nil, in: lineText)
            else {
                continue
            }
            let normalizedWorkspace = normalizePath(workspace)
            let matchesFixture = normalizedFixturePaths.contains { fixturePath in
                normalizedWorkspace == fixturePath
                    || normalizedWorkspace.hasPrefix(fixturePath + "/")
                    || fixturePath.hasPrefix(normalizedWorkspace + "/")
            }
            if matchesFixture {
                return tab
            }
            if fallbackTab == nil, workspace.contains(fallbackWorkspaceName) {
                fallbackTab = tab
            }
        }
    }
    return fallbackTab
}

private func parseFirstString(named key: String, from value: MCPJSONValue) -> String? {
    if let found = findFirstString(named: key, in: value.jsonObject) {
        return found
    }
    let text = flattenedText(from: value)
    let pattern = #""\#(key)"\s*:\s*"([^"]+)""#
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
       match.numberOfRanges >= 2,
       let range = Range(match.range(at: 1), in: text) {
        return String(text[range])
    }
    return nil
}

private func parseFirstTest(from value: MCPJSONValue) -> (targetName: String, identifier: String)? {
    guard let tests = findFirstArray(named: "tests", in: value.jsonObject) else {
        return nil
    }
    for item in tests {
        guard let object = item as? [String: Any],
              let targetName = object["targetName"] as? String,
              let identifier = object["identifier"] as? String
        else {
            continue
        }
        return (targetName, identifier)
    }
    return nil
}

private func parsePreferredRunDestination(from value: MCPJSONValue) -> String? {
    guard let destinations = findFirstArray(named: "destinations", in: value.jsonObject) else {
        return nil
    }
    let candidates = destinations.compactMap { item -> [String: Any]? in
        item as? [String: Any]
    }
    let preferred = candidates.first { destination in
        boolValue(destination["isSimulator"]) == true
            && boolValue(destination["isEligible"]) != false
            && stringValue(destination["platformIdentifier"]) == "com.apple.platform.iphonesimulator"
            && osVersionIsAtLeast27(stringValue(destination["osVersion"]))
    } ?? candidates.first { destination in
        boolValue(destination["isSimulator"]) == true
            && boolValue(destination["isEligible"]) != false
            && stringValue(destination["platformIdentifier"]) == "com.apple.platform.iphonesimulator"
    } ?? candidates.first { destination in
        stringValue(destination["displayTitle"]) == "My Mac"
    }
    return preferred.flatMap { stringValue($0["displayTitle"]) }
}

private func findFirstString(named key: String, in value: Any) -> String? {
    if let object = value as? [String: Any] {
        if let value = object[key] as? String {
            return value
        }
        for child in object.values {
            if let found = findFirstString(named: key, in: child) {
                return found
            }
        }
    } else if let array = value as? [Any] {
        for child in array {
            if let found = findFirstString(named: key, in: child) {
                return found
            }
        }
    } else if let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) {
        return findFirstString(named: key, in: object)
    }
    return nil
}

private func findFirstArray(named key: String, in value: Any) -> [Any]? {
    if let object = value as? [String: Any] {
        if let value = object[key] as? [Any] {
            return value
        }
        for child in object.values {
            if let found = findFirstArray(named: key, in: child) {
                return found
            }
        }
    } else if let array = value as? [Any] {
        for child in array {
            if let found = findFirstArray(named: key, in: child) {
                return found
            }
        }
    } else if let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) {
        return findFirstArray(named: key, in: object)
    }
    return nil
}

private func flattenedText(from value: MCPJSONValue) -> String {
    allStrings(from: value).joined(separator: "\n")
}

private func allStrings(from value: MCPJSONValue) -> [String] {
    var parts: [String] = []
    collectText(value.jsonObject, into: &parts)
    return parts
}

private func collectText(_ value: Any, into parts: inout [String]) {
    if let string = value as? String {
        parts.append(string)
        if let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            collectText(object, into: &parts)
        }
    } else if let object = value as? [String: Any] {
        for value in object.values {
            collectText(value, into: &parts)
        }
    } else if let array = value as? [Any] {
        for value in array {
            collectText(value, into: &parts)
        }
    }
}

private func extractValue(after marker: String, before endMarker: String?, in text: String) -> String? {
    guard let markerRange = text.range(of: marker) else { return nil }
    let tail = text[markerRange.upperBound...]
    let valueSlice: Substring
    if let endMarker, let endRange = tail.range(of: endMarker) {
        valueSlice = tail[..<endRange.lowerBound]
    } else {
        valueSlice = tail[...]
    }
    let trimmed = valueSlice.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func normalizePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func stringValue(_ value: Any?) -> String? {
    value as? String
}

private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    return nil
}

private func osVersionIsAtLeast27(_ value: String?) -> Bool {
    guard let value else { return false }
    let components = value.split(separator: ".").compactMap { Int($0) }
    guard let major = components.first else { return false }
    return major >= 27
}

private func runProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw VerifierFailure(
            "\(executable) \(arguments.joined(separator: " ")) failed with exit code \(process.terminationStatus)"
        )
    }
}

private func jsonString(_ value: MCPJSONValue) -> String {
    if let data = try? JSONEncoder().encode(value),
       let string = String(data: data, encoding: .utf8) {
        return string
    }
    return String(describing: value)
}

private func jsonString(_ value: [String: MCPJSONValue]) -> String {
    if let data = try? JSONEncoder().encode(value),
       let string = String(data: data, encoding: .utf8) {
        return string
    }
    return String(describing: value)
}

private func abbreviate(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit - 3)) + "..."
}

private func formatSeconds(_ seconds: TimeInterval) -> String {
    let hundredths = Int((seconds * 100).rounded())
    let whole = hundredths / 100
    let fraction = abs(hundredths % 100)
    let fractionText = fraction < 10 ? "0\(fraction)" : "\(fraction)"
    return "\(whole).\(fractionText)s"
}

private func errorDescription(_ error: any Error) -> String {
    let nsError = error as NSError
    if nsError.localizedDescription.isEmpty == false {
        return nsError.localizedDescription
    }
    return String(describing: error)
}

private struct VerifierFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
