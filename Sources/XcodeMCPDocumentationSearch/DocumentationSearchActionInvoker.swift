import Foundation
import NIOCore
import XcodeMCPCore

import CryptoKit

package actor LiveDocumentationSearchActionInvoker: DocumentationSearchActionInvoking {
    static let helperProductName = "documentation-search-action-helper"
    private static let defaultMaxResults = 20
    private static let defaultScoreThreshold = 0.4
    private static let helperPreparationTimeout: TimeAmount = .seconds(120)

    private let cacheRoot: URL
    private let processRunner: any ProcessRunning
    private var preparedHelperURLsByPackageRoot: [URL: URL] = [:]
    private var helperPreparationsByPackageRoot: [URL: HelperPreparation] = [:]

    package init(
        cacheRoot: URL = URL.cachesDirectory
            .appendingPathComponent("XcodeMCPKit/documentation-search-action", isDirectory: true),
        processRunner: any ProcessRunning = ProcessRunner()
    ) {
        self.cacheRoot = cacheRoot
        self.processRunner = processRunner
    }

    package func isAvailable(for target: DocumentationSearchInstallation) async -> Bool {
        xcodeRuntime(for: target) != nil
    }

    package func invoke(
        _ invocation: DocumentationSearchActionInvocation,
        timeout: TimeAmount?
    ) async throws -> DocumentationSearchActionOutput {
        guard timeout.map({ $0.nanoseconds > 0 }) ?? true else {
            throw TimeoutError()
        }
        guard let runtime = xcodeRuntime(for: invocation.installation) else {
            throw DocumentationSearchBackendError.unavailable
        }
        let deadline = Deadline.fromNow(timeout)
        let sdkPath = try await macOSSdkPath(for: runtime, deadline: deadline)
        let helper = try await helperURL(for: runtime, sdkPath: sdkPath, deadline: deadline)
        let request = HelperRequest(
            query: invocation.query,
            frameworks: invocation.frameworks.isEmpty ? nil : invocation.frameworks,
            configURL: invocation.asset.configURL.path,
            maxResults: invocation.limit ?? Self.defaultMaxResults,
            scoreThreshold: Self.defaultScoreThreshold
        )
        let requestData = try JSONEncoder().encode(request)
        guard let input = String(data: requestData, encoding: .utf8) else {
            throw DocumentationSearchBackendError.invalidResponse("invalid DocumentationSearch helper request")
        }
        let output = try await runHelperSubprocess(ProcessRequest(
            label: "DocumentationSearchAction",
            executablePath: "/usr/bin/env",
            arguments: helperRuntimeEnvironmentArguments(for: runtime) + [helper.path],
            input: input,
            timeoutNanoseconds: try subprocessTimeoutNanoseconds(until: deadline)
        ))
        guard output.terminationStatus == 0 else {
            throw DocumentationSearchBackendError.invalidResponse(
                "DocumentationSearchAction helper failed: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        guard let data = output.stdout.data(using: .utf8) else {
            throw DocumentationSearchBackendError.invalidResponse("invalid DocumentationSearchAction helper output")
        }
        do {
            return try JSONDecoder().decode(DocumentationSearchActionOutput.self, from: data)
        } catch {
            throw DocumentationSearchBackendError.invalidResponse(
                "DocumentationSearchAction helper returned invalid JSON: \(error)"
            )
        }
    }

    private struct HelperRequest: Sendable, Codable {
        let query: String
        let frameworks: [String]?
        let configURL: String
        let maxResults: Int?
        let scoreThreshold: Double
    }

    private struct XcodeRuntime: Sendable {
        let appURL: URL
        let developerDir: String
        let swiftURL: URL
        let frameworksURL: URL
        let sharedFrameworksURL: URL
        let plugInsURL: URL
        let platformDeveloperLibraryURL: URL
        let version: String
        let buildVersion: String
    }

    private struct HostTarget: Sendable {
        let triple: String
        let swiftInterfaceName: String
    }

    private struct HelperPreparation {
        let id: UUID
        let task: Task<URL, Error>
    }

    static let helperMacOSDeploymentTarget = "15.4"

    private func xcodeRuntime(for target: DocumentationSearchInstallation) -> XcodeRuntime? {
        let appURL = URL(fileURLWithPath: target.appPath)
        let developerDir = appURL.appendingPathComponent("Contents/Developer").path
        let swiftURL = appURL
            .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
        let frameworksURL = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let sharedFrameworksURL = appURL.appendingPathComponent("Contents/SharedFrameworks", isDirectory: true)
        let plugInsURL = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let platformDeveloperLibraryURL = appURL
            .appendingPathComponent("Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", isDirectory: true)
        let dvtFrameworkURL = sharedFrameworksURL
            .appendingPathComponent("DVTFoundation.framework/DVTFoundation")
        let chatFrameworkURL = plugInsURL
            .appendingPathComponent("IDEIntelligenceChat.framework/IDEIntelligenceChat")
        guard FileManager.default.isExecutableFile(atPath: swiftURL.path),
              FileManager.default.isReadableFile(atPath: frameworksURL.path),
              FileManager.default.isReadableFile(atPath: dvtFrameworkURL.path),
              FileManager.default.isReadableFile(atPath: chatFrameworkURL.path),
              FileManager.default.isReadableFile(atPath: platformDeveloperLibraryURL.path) else {
            return nil
        }
        guard (try? hostTarget()) != nil else {
            return nil
        }
        let bundle = Bundle(url: appURL)
        return XcodeRuntime(
            appURL: appURL,
            developerDir: developerDir,
            swiftURL: swiftURL,
            frameworksURL: frameworksURL,
            sharedFrameworksURL: sharedFrameworksURL,
            plugInsURL: plugInsURL,
            platformDeveloperLibraryURL: platformDeveloperLibraryURL,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? target.xcodeVersion,
            buildVersion: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        )
    }

    private func macOSSdkPath(
        for runtime: XcodeRuntime,
        deadline: Deadline?
    ) async throws -> String {
        let output = try await runHelperSubprocess(ProcessRequest(
            label: "DocumentationSearchAction.sdk",
            executablePath: "/usr/bin/env",
            arguments: [
                "DEVELOPER_DIR=\(runtime.developerDir)",
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "--show-sdk-path",
            ],
            input: nil,
            timeoutNanoseconds: try subprocessTimeoutNanoseconds(until: deadline)
        ))
        guard output.terminationStatus == 0 else {
            throw DocumentationSearchBackendError.invalidResponse(
                "xcrun --show-sdk-path failed: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        let sdkPath = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sdkPath.isEmpty == false else {
            throw DocumentationSearchBackendError.invalidResponse("xcrun --show-sdk-path returned empty output")
        }
        return sdkPath
    }

    private func helperURL(
        for runtime: XcodeRuntime,
        sdkPath: String,
        deadline: Deadline?
    ) async throws -> URL {
        let hostTarget = try hostTarget()
        let sourceFingerprint = helperSourceFingerprint(hostTarget: hostTarget)
        let packageRoot = cacheRoot.appendingPathComponent(
            runtimePackageDirectoryName(
                runtime: runtime,
                sdkPath: sdkPath,
                hostTarget: hostTarget,
                sourceFingerprint: sourceFingerprint
            ),
            isDirectory: true
        )
        if let helperURL = preparedHelperURLsByPackageRoot[packageRoot],
           FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL
        }
        if let preparation = helperPreparationsByPackageRoot[packageRoot] {
            return try await awaitHelperPreparation(preparation.task, deadline: deadline)
        }
        let preparationID = UUID()
        let preparationDeadline = Deadline.fromNow(Self.helperPreparationTimeout)
        let preparationTask = Task { [self] in
            do {
                let helperURL = try await prepareHelperURL(
                    runtime: runtime,
                    packageRoot: packageRoot,
                    hostTarget: hostTarget,
                    sdkPath: sdkPath,
                    deadline: preparationDeadline
                )
                finishHelperPreparation(packageRoot: packageRoot, id: preparationID, helperURL: helperURL)
                return helperURL
            } catch {
                finishHelperPreparation(packageRoot: packageRoot, id: preparationID, helperURL: nil)
                throw error
            }
        }
        helperPreparationsByPackageRoot[packageRoot] = HelperPreparation(
            id: preparationID,
            task: preparationTask
        )
        return try await awaitHelperPreparation(preparationTask, deadline: deadline)
    }

    private func prepareHelperURL(
        runtime: XcodeRuntime,
        packageRoot: URL,
        hostTarget: HostTarget,
        sdkPath: String,
        deadline: Deadline?
    ) async throws -> URL {
        let moduleRoot = packageRoot.appendingPathComponent("GeneratedModules", isDirectory: true)
        let sourceURL = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("DocumentationSearchActionHelper", isDirectory: true)
            .appendingPathComponent("main.swift")
        try writeIfChanged(Self.helperPackageManifest, to: packageRoot.appendingPathComponent("Package.swift"))
        try writeIfChanged(
            dvtInterface(target: hostTarget.triple),
            to: moduleRoot
                .appendingPathComponent("DVTFoundation.swiftmodule", isDirectory: true)
                .appendingPathComponent(hostTarget.swiftInterfaceName)
        )
        try writeIfChanged(
            chatInterface(target: hostTarget.triple),
            to: moduleRoot
                .appendingPathComponent("IDEIntelligenceChat.swiftmodule", isDirectory: true)
                .appendingPathComponent(hostTarget.swiftInterfaceName)
        )
        try writeIfChanged(Self.helperSource, to: sourceURL)
        let productsDirectoryURL = try await helperProductsDirectoryURL(
            runtime: runtime,
            packageRoot: packageRoot,
            moduleRoot: moduleRoot,
            sdkPath: sdkPath,
            hostTarget: hostTarget,
            deadline: deadline
        )
        let helperURL = productsDirectoryURL.appendingPathComponent(Self.helperProductName)
        let output = try await runHelperSubprocess(ProcessRequest(
            label: "DocumentationSearchAction.build",
            executablePath: "/usr/bin/env",
            arguments: helperBuildArguments(
                runtime: runtime,
                packageRoot: packageRoot,
                moduleRoot: moduleRoot,
                sdkPath: sdkPath,
                hostTarget: hostTarget,
                mode: .build
            ),
            input: nil,
            timeoutNanoseconds: try subprocessTimeoutNanoseconds(until: deadline)
        ))
        guard output.terminationStatus == 0 else {
            throw DocumentationSearchBackendError.invalidResponse(
                "DocumentationSearchAction helper build failed: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw DocumentationSearchBackendError.invalidResponse("DocumentationSearchAction helper build did not produce executable")
        }
        return helperURL
    }

    private func finishHelperPreparation(packageRoot: URL, id: UUID, helperURL: URL?) {
        guard helperPreparationsByPackageRoot[packageRoot]?.id == id else {
            return
        }
        helperPreparationsByPackageRoot[packageRoot] = nil
        if let helperURL {
            preparedHelperURLsByPackageRoot[packageRoot] = helperURL
        }
    }

    private func awaitHelperPreparation(
        _ task: Task<URL, Error>,
        deadline: Deadline?
    ) async throws -> URL {
        guard let timeoutNanoseconds = try subprocessTimeoutNanoseconds(until: deadline) else {
            return try await task.value
        }
        let waiter = DocumentationSearchActionPreparationWaiter()
        Task {
            do {
                waiter.complete(.success(try await task.value))
            } catch {
                waiter.complete(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutNanoseconds))
                waiter.complete(.failure(TimeoutError()))
            } catch {
                return
            }
        }
        defer {
            timeoutTask.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
            }
        } onCancel: {
            timeoutTask.cancel()
            waiter.complete(.failure(CancellationError()))
        }
    }

    private func helperProductsDirectoryURL(
        runtime: XcodeRuntime,
        packageRoot: URL,
        moduleRoot: URL,
        sdkPath: String,
        hostTarget: HostTarget,
        deadline: Deadline?
    ) async throws -> URL {
        let output = try await runHelperSubprocess(ProcessRequest(
            label: "DocumentationSearchAction.bin-path",
            executablePath: "/usr/bin/env",
            arguments: helperBuildArguments(
                runtime: runtime,
                packageRoot: packageRoot,
                moduleRoot: moduleRoot,
                sdkPath: sdkPath,
                hostTarget: hostTarget,
                mode: .showBinPath
            ),
            input: nil,
            timeoutNanoseconds: try subprocessTimeoutNanoseconds(until: deadline)
        ))
        guard output.terminationStatus == 0 else {
            throw DocumentationSearchBackendError.invalidResponse(
                "DocumentationSearchAction helper bin path resolution failed: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        let productsDirectoryPath = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard productsDirectoryPath.isEmpty == false else {
            throw DocumentationSearchBackendError.invalidResponse("DocumentationSearchAction helper bin path resolution returned empty output")
        }
        return URL(fileURLWithPath: productsDirectoryPath, isDirectory: true)
    }

    private enum HelperBuildMode {
        case build
        case showBinPath
    }

    private func helperBuildArguments(
        runtime: XcodeRuntime,
        packageRoot: URL,
        moduleRoot: URL,
        sdkPath: String,
        hostTarget: HostTarget,
        mode: HelperBuildMode
    ) -> [String] {
        var arguments = [
            "DEVELOPER_DIR=\(runtime.developerDir)",
            runtime.swiftURL.path,
            "build",
        ]
        if mode == .showBinPath {
            arguments.append("--show-bin-path")
        }
        arguments += [
            "--package-path",
            packageRoot.path,
            "--scratch-path",
            packageRoot.appendingPathComponent(".build", isDirectory: true).path,
            "--configuration",
            "release",
        ]
        if mode == .build {
            arguments += [
                "--product",
                Self.helperProductName,
            ]
        }
        arguments += [
            "--triple",
            hostTarget.triple,
            "--sdk",
            sdkPath,
            "--disable-sandbox",
            "-Xswiftc",
            "-I",
            "-Xswiftc",
            moduleRoot.path,
            "-Xswiftc",
            "-F",
            "-Xswiftc",
            runtime.frameworksURL.path,
            "-Xswiftc",
            "-F",
            "-Xswiftc",
            runtime.sharedFrameworksURL.path,
            "-Xswiftc",
            "-F",
            "-Xswiftc",
            runtime.plugInsURL.path,
            "-Xlinker",
            "-F",
            "-Xlinker",
            runtime.frameworksURL.path,
            "-Xlinker",
            "-F",
            "-Xlinker",
            runtime.sharedFrameworksURL.path,
            "-Xlinker",
            "-F",
            "-Xlinker",
            runtime.plugInsURL.path,
            "-Xlinker",
            "-framework",
            "-Xlinker",
            "DVTFoundation",
            "-Xlinker",
            "-framework",
            "-Xlinker",
            "IDEIntelligenceChat",
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            runtime.appURL.appendingPathComponent("Contents").path,
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            runtime.frameworksURL.path,
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            runtime.sharedFrameworksURL.path,
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            runtime.plugInsURL.path,
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            runtime.platformDeveloperLibraryURL.path,
        ]
        return arguments
    }

    private func helperRuntimeEnvironmentArguments(for runtime: XcodeRuntime) -> [String] {
        let frameworkPath = [
            runtime.frameworksURL.path,
            runtime.sharedFrameworksURL.path,
            runtime.plugInsURL.path,
        ].joined(separator: ":")
        let libraryPath = [
            runtime.sharedFrameworksURL.path,
            runtime.platformDeveloperLibraryURL.path,
        ].joined(separator: ":")
        return [
            "DEVELOPER_DIR=\(runtime.developerDir)",
            "DYLD_FRAMEWORK_PATH=\(frameworkPath)",
            "DYLD_LIBRARY_PATH=\(libraryPath)",
            "DYLD_FALLBACK_LIBRARY_PATH=",
            "DYLD_FALLBACK_FRAMEWORK_PATH=",
        ]
    }

    private func hostTarget() throws -> HostTarget {
        #if arch(arm64)
        return HostTarget(
            triple: "arm64-apple-macos\(Self.helperMacOSDeploymentTarget)",
            swiftInterfaceName: "arm64-apple-macos.swiftinterface"
        )
        #else
        throw DocumentationSearchBackendError.invalidResponse("unsupported DocumentationSearchAction host architecture")
        #endif
    }

    private func runtimePackageDirectoryName(
        runtime: XcodeRuntime,
        sdkPath: String,
        hostTarget: HostTarget,
        sourceFingerprint: String
    ) -> String {
        // Separate SwiftPM build artifacts by selected Xcode runtime. SwiftPM owns rebuild decisions inside this directory.
        let input = [
            runtime.appURL.path,
            runtime.swiftURL.path,
            runtime.version,
            runtime.buildVersion,
            sdkPath,
            hostTarget.triple,
            sourceFingerprint,
        ].joined(separator: "\n")
        let runtimeFingerprint = shortSHA256Hex(for: input)
        return "runtime-\(runtimeFingerprint)-sources-\(sourceFingerprint)"
    }

    private func helperSourceFingerprint(hostTarget: HostTarget) -> String {
        shortSHA256Hex(for: [
            Self.helperPackageManifest,
            dvtInterface(target: hostTarget.triple),
            chatInterface(target: hostTarget.triple),
            Self.helperSource,
        ].joined(separator: "\n"))
    }

    private func shortSHA256Hex(for input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hexDigits = Array("0123456789abcdef".utf8)
        let hexBytes = digest.flatMap { byte in
            [
                hexDigits[Int(byte) >> 4],
                hexDigits[Int(byte) & 0x0f],
            ]
        }
        return String(decoding: hexBytes.prefix(16), as: UTF8.self)
    }

    private func subprocessTimeoutNanoseconds(until deadline: Deadline?) throws -> Int64? {
        guard let deadline else {
            return nil
        }
        let remaining = deadline.remaining()
        guard remaining.nanoseconds > 0 else {
            throw TimeoutError()
        }
        return remaining.nanoseconds
    }

    private func runHelperSubprocess(_ request: ProcessRequest) async throws -> ProcessOutput {
        do {
            return try await processRunner.run(request)
        } catch is ProcessTimeoutError {
            throw TimeoutError()
        }
    }

    private func writeIfChanged(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            return
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

}
