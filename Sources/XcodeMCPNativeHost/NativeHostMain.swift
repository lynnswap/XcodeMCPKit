import AppKit
import Darwin
import Dispatch
import Foundation
import XcodeMCPInstallation
import XcodeMCPNativeRuntime
import XcodeMCPWire

private struct HostArguments {
    var developerDirectory: String?
    var artifactsDirectory: String?
    var crashCacheDirectory: String?
    var maxMessageBytes = 32 * 1024 * 1024
    var sharesCompilationCache = false
    var help = false

    init(_ values: [String]) throws {
        var index = 0
        while index < values.count {
            let argument = values[index]
            index += 1
            if argument == "--help" || argument == "-h" { help = true; continue }
            if argument == "--share-compilation-cache" { sharesCompilationCache = true; continue }
            guard index < values.count else { throw NativeRuntimeError.invalidRequest("Missing value for \(argument)") }
            let value = values[index]
            index += 1
            switch argument {
            case "--developer-dir": developerDirectory = value
            case "--artifacts-root": artifactsDirectory = value
            case "--crash-cache-root": crashCacheDirectory = value
            case "--max-message-bytes":
                guard let bytes = Int(value), bytes > 0 else { throw NativeRuntimeError.invalidRequest("Message size must be a positive integer") }
                maxMessageBytes = bytes
            default: throw NativeRuntimeError.invalidRequest("Unknown native host option '\(argument)'")
            }
        }
    }
}

@main
private enum NativeHostMain {
    @MainActor static func main() {
        do {
            let arguments = try HostArguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.help {
                print("""
                    Usage: xcode-mcp-native-host [--developer-dir path] [--artifacts-root path] [--crash-cache-root path] [--max-message-bytes bytes] [--share-compilation-cache]
                    Run from the packaged native host application to provide headless Xcode MCP over STDIO.
                    Crash data defaults to ~/Library/Application Support/XcodeMCPKit/CrashCache, independently of temporary request artifacts.
                    """)
                return
            }
            let developerDirectory = try selectedDeveloperDirectory(arguments)
            let installation = try NativeXcodeInstallation(developerDirectory: developerDirectory)
            try prepareLoaderEnvironment(installation, sharesCompilationCache: arguments.sharesCompilationCache)
            guard Bundle.main.bundleIdentifier == "com.apple.dt.mcp-server" else {
                throw NativeRuntimeError.unavailable("Run the packaged XcodeMCPNativeHost.app executable. Use scripts/build-native-host.sh to assemble it.")
            }
            let outputDescriptor = dup(STDOUT_FILENO)
            guard outputDescriptor >= 0 else { throw NativeRuntimeError.unavailable("Cannot retain native MCP stdout: \(unsafe String(cString: strerror(errno)))") }
            guard fcntl(outputDescriptor, F_SETFD, FD_CLOEXEC) != -1, dup2(STDERR_FILENO, STDOUT_FILENO) != -1 else {
                close(outputDescriptor)
                throw NativeRuntimeError.unavailable("Cannot separate native framework output from MCP stdout")
            }
            signal(SIGPIPE, SIG_IGN)
            let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
            let bootstrap = NativeApplicationBootstrap()
            let application = try bootstrap.application(for: installation, sharesCompilationCache: arguments.sharesCompilationCache)
            let artifacts = arguments.artifactsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("XcodeMCPNativeHost", isDirectory: true)
            let crashCache = try arguments.crashCacheDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("XcodeMCPKit/CrashCache", isDirectory: true)
            let maxMessageBytes = arguments.maxMessageBytes
            Task { @MainActor in
                let session: NativeMCPSession
                do {
                    try await bootstrap.initialize(installation: installation)
                    let backend = try await NativeXcodeBackend(installation: installation)
                    session = NativeMCPSession(backend: backend, artifactsRoot: artifacts, crashCacheRoot: crashCache) { data in
                        try output.write(contentsOf: data + Data([0x0A]))
                    }
                } catch {
                    report("Native host failed: \(error)")
                    terminate(application, failure: true)
                    return
                }
                let failures = AsyncStream<any Error>.makeStream()
                await session.setFailureHandler { error in
                    failures.continuation.yield(error)
                    failures.continuation.finish()
                }
                // Whichever ends first stops the host: input, its failure, or a failure that makes the
                // process unusable. Framing runs off the main actor, which Xcode's models use.
                let outcome = await withTaskGroup(of: HostOutcome?.self) { group in
                    group.addTask { await consumeInput(into: session, maxMessageBytes: maxMessageBytes) }
                    group.addTask {
                        for await error in failures.stream { return .failed(error) }
                        return nil
                    }
                    var first: HostOutcome = .inputEnded
                    while let next = await group.next() {
                        guard let next else { continue }
                        first = next
                        break
                    }
                    group.cancelAll()
                    return first
                }
                var problem: String?
                switch outcome {
                case .inputEnded: break
                case .inputFailed(let error): problem = "Native host input failed: \(error)"
                case .failed(let error): problem = "Native host failed: \(error)"
                }
                do { try await session.shutdown() }
                catch { problem = (problem.map { $0 + "; " } ?? "") + "cleanup failed: \(error)" }
                if let problem { report(problem) }
                terminate(application, failure: problem != nil)
            }
            withExtendedLifetime(bootstrap) {
                application.run()
            }
        } catch {
            report("Native host startup failed: \(error)")
            exit(1)
        }
    }

    private static func selectedDeveloperDirectory(_ arguments: HostArguments) throws -> URL {
        try XcodeInstallationDiscovery.live.resolve(
            required: arguments.developerDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) },
            report: { report($0) }
        ).developerDirectory
    }

    private static func prepareLoaderEnvironment(_ installation: NativeXcodeInstallation, sharesCompilationCache: Bool) throws {
        let current = ProcessInfo.processInfo.environment
        let prepared = installation.launchEnvironment(base: current, sharesCompilationCache: sharesCompilationCache)
        let loaderChanged = current["DYLD_FRAMEWORK_PATH"] != prepared["DYLD_FRAMEWORK_PATH"]
            || current["DYLD_LIBRARY_PATH"] != prepared["DYLD_LIBRARY_PATH"]
        for (key, value) in prepared where current[key] != value {
            guard unsafe setenv(key, value, 1) == 0 else { throw NativeRuntimeError.unavailable("Cannot configure native host environment '\(key)'") }
        }
        guard loaderChanged else { return }
        let arguments = unsafe CommandLine.arguments.map { unsafe strdup($0) }
        defer { unsafe arguments.forEach { argument in unsafe free(argument) } }
        var pointers = unsafe arguments + [nil]
        pointers.withUnsafeMutableBufferPointer { buffer in
            _ = unsafe execv(CommandLine.arguments[0], buffer.baseAddress)
        }
        throw NativeRuntimeError.unavailable("Cannot restart native host with Xcode's loader paths: \(unsafe String(cString: strerror(errno)))")
    }

    private enum HostOutcome: Sendable {
        case inputEnded
        case inputFailed(any Error)
        case failed(any Error)
    }

    private static func consumeInput(into session: NativeMCPSession, maxMessageBytes: Int) async -> HostOutcome {
        let framer = StdioFramer(mode: .delimitedMessages)
        let input = StandardInput()
        do {
            for try await chunk in input.chunks {
                let result = framer.append(chunk)
                guard framer.bufferedMessageByteCount <= maxMessageBytes else {
                    throw NativeRuntimeError.invalidRequest("Native MCP input exceeds the configured message limit")
                }
                if let violation = result.protocolViolation {
                    throw NativeRuntimeError.invalidRequest("Invalid native MCP framing: \(violation.reason.rawValue)")
                }
                for message in result.messages {
                    guard message.count <= maxMessageBytes else {
                        throw NativeRuntimeError.invalidRequest("Native MCP message exceeds the configured message limit")
                    }
                }
                try await session.receive(result.messages)
                input.consumed()
            }
            return .inputEnded
        } catch {
            return .inputFailed(error)
        }
    }

    private static func report(_ message: String) {
        NativeHostDiagnostic.report(message)
    }

    @MainActor private static func terminate(_ application: NSApplication, failure: Bool) {
        if failure {
            // AppKit terminates with status zero after its lifecycle notifications.
            // Retain those notifications while reporting failed host sessions to the parent.
            _ = atexit_b { _exit(EXIT_FAILURE) }
        }
        application.terminate(nil)
    }
}

/// Reads stdin on its own thread, one chunk ahead of the consumer, so the pipe keeps exerting
/// backpressure. Cancelling the consumer ends iteration; the reader then stops at its next chunk.
private final class StandardInput: Sendable {
    let chunks: AsyncThrowingStream<Data, any Error>
    private let demand = DispatchSemaphore(value: 0)

    init() {
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.chunks = chunks
        let demand = demand
        DispatchQueue(label: "xcode.native.stdin").async {
            while true {
                var data = Data(count: 64 * 1024)
                let count = unsafe data.withUnsafeMutableBytes { bytes in
                    unsafe Darwin.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    data.count = count
                    guard case .enqueued = continuation.yield(data) else { return }
                    demand.wait()
                } else if count == 0 {
                    continuation.finish()
                    return
                } else if errno != EINTR {
                    continuation.finish(throwing: NativeRuntimeError.unavailable(
                        "Native MCP stdin read failed: \(unsafe String(cString: strerror(errno)))"))
                    return
                }
            }
        }
    }

    /// Lets the reader fetch the next chunk.
    func consumed() { demand.signal() }
}
