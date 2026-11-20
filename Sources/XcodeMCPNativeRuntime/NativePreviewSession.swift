import Darwin
import Foundation
import XcodeMCPWire

/// One workspace's preview state: its staged renderers, its temporary Simulator device, and the apps installed on that device.
///
/// `NativePreviewTool` changes a session only while it holds the workspace's render queue access.
/// Closing a session stops its renderers and deletes its own device and directory, never the user's Simulator devices.
@MainActor
final class NativePreviewSession {
    struct MetadataKey: Hashable {
        let index: Int
        let localization: String?
    }

    final class MetadataEntry {
        let response: PreviewRendererResult
        var isWidgetPreview: Bool?
        var isComplicationPreview: Bool?

        init(response: PreviewRendererResult) { self.response = response }
    }

    struct SimulatorDestination: Equatable {
        let identifier: String
        let systemVersion: String?

        init(_ build: NativePreviewBuild.Result) {
            identifier = build.destinationIdentifier
            systemVersion = build.systemVersion
        }

        init(_ destination: NativePreviewBuild.Destination) {
            identifier = destination.identifier
            systemVersion = destination.systemVersion
        }
    }

    struct RetainedPlan {
        let requestKey: [String: JSONValue]
        let sourcePath: String
        let source: URL
        let location: NativePreviewDefinitions.Definition
        let index: Int
        let localization: String?
        let context: NativePreviewBuild.PlanningContext
        let destination: NativePreviewBuild.DestinationSelection
        var certificate: BuildCertificate?
    }

    struct BuildCertificate {
        let build: NativePreviewBuild.Result
        let workspaceBuilder: AnyObject
        let inputs: NativePreviewInputSnapshot
        let generatedInputs: NativePreviewInputSnapshot
    }

    final class RendererStage {
        var preparation: NativePreviewTool.RendererPreparation
        var requestDirectory: URL?
        var task: Task<Void, any Error>?
        @MainActor var processFailure: (any Error)? { didSet { processFailureWake?() } }
        var processFailureWake: (@MainActor () -> Void)?
        var installed = false
        var launched = false
        var localization: String?
        var nativeWidgetPrepared = false
        var nativeHostPrepared = false
        var containingApp: URL?
        var processIdentifier: Int32?
        var executable: URL?
        var documents: URL?
        var processLog: URL?

        init(_ preparation: NativePreviewTool.RendererPreparation) { self.preparation = preparation }
    }

    struct Simulator {
        let identifier: String
        let destination: [String: JSONValue]
        let deviceType: URL
    }

    let directory: URL
    let artifactsRoot: URL
    let productDigests = NativePreviewProductSignature.DigestCache()
    var signature: NativePreviewProductSignature?
    var additionalProducts: [URL] = []
    var stages: [String: RendererStage] = [:]
    var simulator: Simulator?
    var simulatorDestination: SimulatorDestination?
    var installedApplications: Set<String> = []
    var metadata: [MetadataKey: MetadataEntry] = [:]
    var activeUIStage: RendererStage?
    var plan: RetainedPlan?
    var inputRevision: UInt64 = 0

    var stagesDirectory: URL { directory.appendingPathComponent("Stages", isDirectory: true) }
    var simulatorDeviceSet: URL { directory.appendingPathComponent("Devices", isDirectory: true) }
    var simctlArguments: [String] { ["simctl", "--set", simulatorDeviceSet.path] }

    init(directory: URL, artifactsRoot: URL) {
        self.directory = directory
        self.artifactsRoot = artifactsRoot
    }

    func stop(_ stage: RendererStage, process: NativePreviewProcess) async throws {
        if let identifier = stage.processIdentifier, let executable = stage.executable {
            try await Self.terminateRenderer(identifier, executable: executable)
        }
        stage.task?.cancel()
        if let task = stage.task {
            do { try await task.value }
            catch let failure as NativePreviewProcess.TerminationFailure {
                if failure.process.isRunning { throw failure }
            }
        }
        stage.task = nil
        if stage.requestDirectory == nil, let log = stage.processLog, FileManager.default.fileExists(atPath: log.path) {
            let lines = String(decoding: try Data(contentsOf: log), as: UTF8.self).split(whereSeparator: \.isNewline)
            if let line = lines.first(where: { $0.hasPrefix("XcodeMCPPreviewSession:") }) {
                stage.requestDirectory = URL(filePath: String(line.dropFirst("XcodeMCPPreviewSession:".count)), directoryHint: .isDirectory)
            }
        }
        if let directory = stage.requestDirectory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        stage.launched = false
        stage.requestDirectory = nil
        stage.processFailure = nil
        stage.processIdentifier = nil
        stage.processLog = nil
        if self.activeUIStage === stage { self.activeUIStage = nil }
    }

    static func rendererIsRunning(_ identifier: Int32, executable: URL) throws -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { bytes in
            unsafe proc_pidpath(identifier, bytes.baseAddress, UInt32(bytes.count))
        }
        if count <= 0 {
            guard errno == ESRCH || errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return false
        }
        let path = buffer.withUnsafeBufferPointer { unsafe String(cString: $0.baseAddress!) }
        // A stopped renderer's PID may have been reused by an unrelated process.
        return URL(filePath: path).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
    }

    private static func terminateRenderer(_ identifier: Int32, executable: URL) async throws {
        guard try rendererIsRunning(identifier, executable: executable) else { return }
        guard kill(identifier, SIGTERM) == 0 || errno == ESRCH else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try rendererIsRunning(identifier, executable: executable) {
            if ContinuousClock.now >= deadline {
                guard kill(identifier, SIGKILL) == 0 || errno == ESRCH else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        if try rendererIsRunning(identifier, executable: executable) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while try rendererIsRunning(identifier, executable: executable), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        if try rendererIsRunning(identifier, executable: executable) {
            throw NativeRuntimeError.invocation("The preview renderer process \(identifier) did not terminate")
        }
    }

    private func resetStages(process: NativePreviewProcess) async throws {
        for stage in self.stages.values { try await stop(stage, process: process) }
        if let simulator = self.simulator {
            for identifier in self.installedApplications.sorted() {
                _ = try await process.xcrun(self.simctlArguments + ["uninstall", simulator.identifier, identifier])
                self.installedApplications.remove(identifier)
            }
        }
        self.stages.removeAll()
        self.metadata.removeAll()
        self.plan = nil
        if FileManager.default.fileExists(atPath: self.stagesDirectory.path) {
            try FileManager.default.removeItem(at: self.stagesDirectory)
        }
    }

    func close(installation: NativeXcodeInstallation) async throws {
        let process = NativePreviewProcess(installation: installation, artifacts: self.directory.deletingLastPathComponent())
        var failures: [String] = []
        for stage in self.stages.values {
            do { try await stop(stage, process: process) }
            catch { failures.append(String(describing: error)) }
        }
        if let simulator = self.simulator {
            do {
                _ = try await process.xcrun(self.simctlArguments + ["delete", simulator.identifier])
                self.simulator = nil
                self.installedApplications.removeAll()
            } catch { failures.append("Cannot delete preview Simulator \(simulator.identifier): \(error)") }
        }
        if failures.isEmpty {
            do { try FileManager.default.removeItem(at: self.directory) }
            catch { failures.append("Cannot remove \(self.directory.path): \(error)") }
        }
        if !failures.isEmpty { throw NativeRuntimeError.invocation(failures.joined(separator: "; ")) }
    }

    func update(build: NativePreviewBuild.Result, source: URL,
                        platform: NativePreviewPlatform, signature retainedSignature: NativePreviewProductSignature? = nil,
                        process: NativePreviewProcess) async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/\(platform.helperDirectory)")
        let signature: NativePreviewProductSignature
        if let retainedSignature { signature = retainedSignature }
        else {
            signature = try await NativePreviewProductSignature.make(build: build, source: source, helper: helper,
                digestCache: self.productDigests, additionalProducts: self.additionalProducts)
        }
        if self.signature != signature {
            try await resetStages(process: process)
            self.additionalProducts = []
            self.signature = try await NativePreviewProductSignature.make(build: build, source: source, helper: helper,
                digestCache: self.productDigests)
        } else { self.signature = signature }
        if let simulator = self.simulator, self.simulatorDestination != SimulatorDestination(build) {
            _ = try await process.xcrun(self.simctlArguments + ["delete", simulator.identifier])
            self.simulator = nil
            self.simulatorDestination = nil
            self.installedApplications.removeAll()
        }
    }

    func prepareSimulator(destination: NativePreviewBuild.Destination,
                                  process: NativePreviewProcess) async throws {
        guard destination.previewPlatform?.isSimulator == true else { return }
        try await prepareSimulator(destination: SimulatorDestination(destination),
            platformName: destination.platformName, deviceModelName: destination.deviceModelName, process: process)
    }

    func prepareSimulator(destination: SimulatorDestination,
                                  platformName: String?, deviceModelName: String?, process: NativePreviewProcess) async throws {
        if let simulator = self.simulator, self.simulatorDestination != destination {
            _ = try await process.xcrun(self.simctlArguments + ["delete", simulator.identifier])
            self.simulator = nil
            self.simulatorDestination = nil
            self.installedApplications.removeAll()
        }
        guard self.simulator == nil else { return }
        // Finish allocation before cancellation cleanup so the session owns every created device.
        let allocation = Task { @MainActor in
            try await self.createSimulator(destination: destination, platformName: platformName,
                deviceModelName: deviceModelName, deviceSet: self.simulatorDeviceSet, process: process)
        }
        let simulator = try await allocation.value
        self.simulator = simulator
        self.simulatorDestination = destination
        _ = try await process.xcrun(self.simctlArguments + ["boot", simulator.identifier])
        _ = try await process.xcrun(self.simctlArguments + ["bootstatus", simulator.identifier, "-b"])
    }

    private func createSimulator(destination: SimulatorDestination, platformName: String?, deviceModelName: String?, deviceSet: URL,
                                 process: NativePreviewProcess) async throws -> Simulator {
        let inventoryData = Data(try await process.xcrun(["simctl", "list", "--json"]).utf8)
        guard let inventory = try JSONSerialization.jsonObject(with: inventoryData) as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("Simulator inventory is not a JSON object")
        }
        let destinations = inventory["devices"] as? [String: [[String: Any]]] ?? [:]
        guard let selected = destinations.compactMap({ runtime, devices -> (String, [String: Any])? in
            devices.first(where: { $0["udid"] as? String == destination.identifier }).map { (runtime, $0) }
        }).first, let deviceID = selected.1["deviceTypeIdentifier"] as? String else {
            throw NativeRuntimeError.unavailable("The selected Simulator \(destination.identifier) is no longer installed")
        }
        let runtimeID = selected.0
        let type = (inventory["devicetypes"] as? [[String: Any]])?.first { $0["identifier"] as? String == deviceID }
        guard let path = type?["bundlePath"] as? String else { throw NativePipelineRequired() }
        let deviceType = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: deviceSet, withIntermediateDirectories: true)
        let identifier = try await process.xcrun(["simctl", "--set", deviceSet.path, "create",
            "XcodeMCPPreview-\(UUID().uuidString)", deviceID, runtimeID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Simulator(identifier: identifier,
            destination: ["identifier": .string(destination.identifier),
                "platformName": .string(platformName ?? "iOS"),
                "deviceModelName": .string(deviceModelName ?? selected.1["name"] as? String ?? deviceID),
                "systemVersion": .string(destination.systemVersion ?? runtimeID)], deviceType: deviceType)
    }
}
