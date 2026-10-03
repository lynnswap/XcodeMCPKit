import AppKit
import Darwin
import Dispatch
import Foundation
import XcodeMCPNativeRuntime
import XcodeMCPWire

private struct HostArguments {
    var developerDirectory: String?
    var artifactsDirectory: String?
    var maxMessageBytes = 32 * 1024 * 1024
    var help = false

    init(_ values: [String]) throws {
        var index = 0
        while index < values.count {
            let argument = values[index]
            index += 1
            if argument == "--help" || argument == "-h" { help = true; continue }
            guard index < values.count else { throw NativeRuntimeError.invalidRequest("Missing value for \(argument)") }
            let value = values[index]
            index += 1
            switch argument {
            case "--developer-dir": developerDirectory = value
            case "--artifacts-root": artifactsDirectory = value
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
                print("Usage: xcode-mcp-native-host [--developer-dir path] [--artifacts-root path] [--max-message-bytes bytes]\nRun from the packaged native host application to provide Xcode MCP over STDIO.")
                return
            }
            let developerDirectory = try selectedDeveloperDirectory(arguments)
            let installation = try NativeXcodeInstallation(developerDirectory: developerDirectory)
            try prepareLoaderEnvironment(installation)
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
            let application = try bootstrap.application(for: installation)
            let artifacts = arguments.artifactsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("XcodeMCPNativeHost", isDirectory: true)
            Task { @MainActor in
                do {
                    try await bootstrap.initialize(installation: installation)
                    let backend = try await NativeXcodeBackend(installation: installation)
                    let session = NativeMCPSession(backend: backend, artifactsRoot: artifacts) { data in
                        try output.write(contentsOf: data + Data([0x0A]))
                    }
                    let framer = StdioFramer()
                    do {
                        for try await chunk in standardInput() {
                            let result = framer.append(chunk)
                            guard result.bufferedByteCount <= arguments.maxMessageBytes else {
                                throw NativeRuntimeError.invalidRequest("Native MCP input exceeds the configured message limit")
                            }
                            if let violation = result.protocolViolation {
                                throw NativeRuntimeError.invalidRequest("Invalid native MCP framing: \(violation.reason.rawValue)")
                            }
                            for message in result.messages {
                                guard message.count <= arguments.maxMessageBytes else {
                                    throw NativeRuntimeError.invalidRequest("Native MCP message exceeds the configured message limit")
                                }
                                try session.receive(message)
                            }
                        }
                    } catch {
                        do { try await session.shutdown() }
                        catch let cleanup {
                            report("Native host input failed: \(error); cleanup failed: \(cleanup)")
                            terminate(application, failure: true)
                            return
                        }
                        throw error
                    }
                    try await session.shutdown()
                } catch {
                    report("Native host failed: \(error)")
                    terminate(application, failure: true)
                    return
                }
                terminate(application, failure: false)
            }
            application.run()
        } catch {
            report("Native host startup failed: \(error)")
            exit(1)
        }
    }

    private static func selectedDeveloperDirectory(_ arguments: HostArguments) throws -> URL {
        if let path = arguments.developerDirectory ?? ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NativeRuntimeError.unavailable("xcode-select could not locate Xcode") }
        return URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }

    private static func prepareLoaderEnvironment(_ installation: NativeXcodeInstallation) throws {
        let current = ProcessInfo.processInfo.environment
        let prepared = installation.launchEnvironment(base: current)
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

    private static func standardInput() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: DispatchQueue(label: "xcode.native.stdin"))
            source.setEventHandler {
                do {
                    var data = Data(count: 64 * 1024)
                    let count = unsafe data.withUnsafeMutableBytes { bytes in
                        unsafe Darwin.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
                    }
                    if count > 0 {
                        data.count = count
                        continuation.yield(data)
                    } else if count == 0 {
                        continuation.finish()
                        source.cancel()
                    } else if errno != EINTR {
                        throw NativeRuntimeError.unavailable("Native MCP stdin read failed: \(unsafe String(cString: strerror(errno)))")
                    }
                } catch { continuation.finish(throwing: error); source.cancel() }
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
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
