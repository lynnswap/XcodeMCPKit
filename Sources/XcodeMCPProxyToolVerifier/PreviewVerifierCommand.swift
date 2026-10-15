import Foundation
import XcodeMCPKit

enum PreviewVerifierCommand {
    static func run(arguments: [String]) async throws -> Int32 {
        let options = try PreviewVerifierOptions(arguments)
        if options.action == "help" { print(usage); return 0 }
        let repository = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        switch options.action {
        case "list":
            for fixture in try PreviewFixtureDefinition.load(in: repository) {
                print("\(fixture.id): \(fixture.cases.map(\.id).joined(separator: ", "))")
            }
            return 0
        case "prepare":
            let name = try options.required("fixture")
            guard let definition = try PreviewFixtureDefinition.load(in: repository).first(where: { $0.id == name }) else {
                throw VerifierFailure("Unknown preview fixture: \(name). Use previews list.")
            }
            let output = options.output
            _ = try PreparedPreviewFixture.prepare(definition: definition, repository: repository, output: output,
                deviceName: options.values["device-name"], buildSettings: options.url("build-settings"))
            print("Prepared fixture: \(output.path)")
            return 0
        case "capture":
            return try await capture(options: options, repository: repository)
        case "compare":
            let comparison = try PreviewComparison.compare(native: options.requiredURL("native"),
                headless: options.requiredURL("headless"))
            let output = options.output
            try createPreviewOutput(output)
            try writePreviewJSON(comparison, to: output.appendingPathComponent("comparison.json"))
            print("Comparison \(comparison.passed ? "passed" : "failed"): \(output.path)")
            return comparison.passed ? 0 : 1
        default:
            throw VerifierFailure("Unknown previews action: \(options.action). Use previews --help.")
        }
    }

    private static func capture(options: PreviewVerifierOptions, repository: URL) async throws -> Int32 {
        let fixtureRoot = try options.requiredURL("fixture")
        let fixture = try PreparedPreviewFixture.load(at: fixtureRoot)
        let caseName = try options.required("case")
        guard let preview = fixture.definition.cases.first(where: { $0.id == caseName }) else {
            throw VerifierFailure("Unknown case \(caseName) in fixture \(fixture.definition.id)")
        }
        let developer = try options.requiredURL("developer-dir")
        let destination = try options.required("destination")
        guard let backend = PreviewBackend(rawValue: options.values["backend"] ?? "headless") else {
            throw VerifierFailure("--backend must be headless or native")
        }
        let xcodePID = backend == .native ? try options.required("xcode-pid") : nil
        let timeout = try options.timeout()
        let output = options.output
        try createPreviewOutput(output)
        let projectRoot = output.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("Project"), to: projectRoot)
        let project = projectRoot.appendingPathComponent(fixture.definition.project)
        var runner = PreviewCaptureRunner(output: output, projectRoot: projectRoot, project: project,
            report: PreviewCaptureReport(backend: backend, fixture: fixture.definition.id, preview: preview,
                inputFiles: try previewFileDigests(in: projectRoot), developerDirectory: developer.path,
                requestedDestination: destination, timeout: timeout))
        let xcode = developer.deletingLastPathComponent().deletingLastPathComponent()
        var openedNativeDocument = false
        var client: XcodeMCP?
        do {
            runner.report.xcodeVersion = try previewProcessOutput(executable: developer.appendingPathComponent("usr/bin/xcodebuild"),
                arguments: ["-version"])
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = developer.path
            let executable: URL
            let arguments: [String]
            if backend == .native {
                executable = developer.appendingPathComponent("usr/bin/mcpbridge")
                arguments = []
                environment["MCP_XCODE_PID"] = xcodePID
                let processPath = try previewProcessOutput(executable: URL(filePath: "/bin/ps"),
                    arguments: ["-p", try options.required("xcode-pid"), "-o", "comm="])
                guard URL(filePath: processPath).resolvingSymlinksInPath() == xcode.appendingPathComponent("Contents/MacOS/Xcode").resolvingSymlinksInPath() else {
                    throw VerifierFailure("--xcode-pid does not identify the Xcode selected by --developer-dir")
                }
                openedNativeDocument = true
                try runProcess(executable: "/usr/bin/open", arguments: ["-g", "-a", xcode.path, project.path], currentDirectory: repository)
            } else {
                let host = options.url("native-host") ?? repository.appendingPathComponent(".build/debug/XcodeMCPNativeHost.app")
                if options.url("native-host") == nil {
                    try runProcess(executable: "/bin/bash", arguments: ["scripts/build-native-host.sh", "--output", host.path,
                        "--developer-dir", developer.path],
                        currentDirectory: repository)
                }
                executable = host.appendingPathComponent("Contents/MacOS/xcode-mcp-native-host")
                arguments = ["--developer-dir", developer.path, "--artifacts-root", output.appendingPathComponent("artifacts").path]
            }
            runner.report.executable = executable.path
            runner.report.executableSHA256 = try previewSHA256(executable)
            let connection = try await XcodeMCP(configuration: XcodeMCPConfiguration(
                transport: .localBridge(.custom(command: executable.path, arguments: arguments, environment: environment)),
                clientName: "PreviewToolVerifier", clientVersion: "1", requestTimeout: .seconds(timeout + 60)))
            client = connection
            await runner.capture(client: connection)
        } catch {
            runner.report.failure = errorDescription(error)
        }
        if openedNativeDocument {
            do {
                let script = "tell application \(appleScriptString(xcode.path))\n"
                    + "repeat with d in workspace documents\n"
                    + "if path of d is \(appleScriptString(project.path)) then\nclose d saving no\nexit repeat\nend if\n"
                    + "end repeat\nrepeat with d in workspace documents\n"
                    + "if path of d is \(appleScriptString(project.path)) then error \"Fixture document is still open\"\n"
                    + "end repeat\nend tell"
                try runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script], currentDirectory: repository)
                runner.report.nativeDocumentClosed = true
            } catch { runner.report.cleanupErrors.append(errorDescription(error)) }
        }
        if let client {
            await client.close()
            runner.report.clientClosed = true
        }
        try runner.save()
        print("Capture \(runner.report.passed ? "passed" : "failed"): \(output.path)")
        return runner.report.passed ? 0 : 1
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let usage = """
    Usage:
      xcode-mcp-proxy-tool-verifier previews list
      xcode-mcp-proxy-tool-verifier previews prepare --fixture NAME --output DIRECTORY
        [--device-name NAME] [--build-settings JSON_FILE]
      xcode-mcp-proxy-tool-verifier previews capture --fixture DIRECTORY --case NAME
        --developer-dir PATH --destination TITLE --output DIRECTORY
        [--backend headless|native] [--native-host APP] [--xcode-pid PID] [--timeout SECONDS]
      xcode-mcp-proxy-tool-verifier previews compare --native CAPTURE --headless CAPTURE --output DIRECTORY

    prepare copies a tracked project and its source variant. build-settings JSON is
    target name -> configuration name -> setting name -> string value.
    capture uses another owned copy. Native capture requires a running Xcode PID,
    opens only that copy, and closes its document afterward. Headless is the default;
    without --native-host it builds the repository's signed debug host first.
    compare requires successful captures of the same case, inputs, and Xcode build.
    Captures retain raw responses, PNGs, selection, source hashes, and cleanup results.
    """
}

struct PreviewVerifierOptions {
    let action: String
    let values: [String: String]
    private let defaultOutput = URL(filePath: "ProxyToolVerifierOutput/Preview-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(_ arguments: [String]) throws {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            action = "help"; values = [:]; return
        }
        action = arguments[0]
        let known: Set<String> = ["fixture", "output", "device-name", "build-settings", "case", "developer-dir",
            "destination", "backend", "native-host", "xcode-pid", "timeout", "native", "headless"]
        var parsed: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), known.contains(String(flag.dropFirst(2))) else {
                throw VerifierFailure("Unknown previews option: \(flag)")
            }
            guard index + 1 < arguments.count else { throw VerifierFailure("\(flag) requires a value") }
            parsed[String(flag.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        values = parsed
    }

    var output: URL { url("output") ?? defaultOutput }
    func url(_ name: String) -> URL? { values[name].map { URL(filePath: $0) } }
    func requiredURL(_ name: String) throws -> URL { URL(filePath: try required(name)) }
    func required(_ name: String) throws -> String {
        guard let value = values[name] else { throw VerifierFailure("previews \(action) requires --\(name)") }
        return value
    }
    func timeout() throws -> Int {
        guard let value = Int(values["timeout"] ?? "240"), value > 0 else {
            throw VerifierFailure("--timeout requires a positive number of seconds")
        }
        return value
    }
}

func previewProcessOutput(executable: URL, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else { throw VerifierFailure("\(executable.lastPathComponent): \(text)") }
    return text
}
