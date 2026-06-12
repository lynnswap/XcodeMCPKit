import AppKit
import Darwin
import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP

package enum DocumentationToolListUpdate: Sendable {
    case unchanged
    case unavailable
    case available(JSONValue)
}

/// The manager's classification of one DocumentationSearch attempt.
/// `noProvider` means no live provider could serve the call and the
/// request should be forwarded to the regular mcpbridge upstream.
package enum DocumentationProviderCallOutcome: Sendable {
    case handled(Data)
    case noProvider
    case failed(any Error)
}

package protocol DocumentationProviderManaging: Sendable {
    func prewarm(requestTimeout: TimeAmount?) async -> DocumentationToolListUpdate
    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationToolListUpdate
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProviderCallOutcome
    func invalidate(reason: String) async
    func shutdown() async
}

package enum DocumentationToolCatalog {
    package static let toolName = "DocumentationSearch"

    package static func applying(
        _ update: DocumentationToolListUpdate,
        to result: JSONValue
    ) -> JSONValue {
        switch update {
        case .unchanged:
            return result
        case .unavailable:
            return removingDocumentationSearch(from: result)
        case .available(let descriptor):
            return replacingDocumentationSearch(in: result, with: descriptor)
        }
    }

    package static func descriptor(in result: JSONValue) -> JSONValue? {
        guard case .object(let object) = result,
              case .array(let tools)? = object["tools"] else {
            return nil
        }
        return tools.first { value in
            guard case .object(let toolObject) = value,
                  case .string(let name)? = toolObject["name"] else {
                return false
            }
            return name == toolName
        }
    }

    package static func responseIsDocumentationNotEnabled(_ data: Data) -> Bool {
        responseErrorTexts(in: data).contains { text in
            let normalized = text.lowercased()
            return normalized.contains("documentationsearch")
                && normalized.contains("not enabled")
        }
    }

    package static func responseIsToolError(_ data: Data) -> Bool {
        responseErrorObjects(in: data).isEmpty == false || responseResultObjects(in: data).contains { object in
            object["isError"] as? Bool == true
        }
    }

    private static func replacingDocumentationSearch(
        in result: JSONValue,
        with descriptor: JSONValue
    ) -> JSONValue {
        guard case .object(var object) = result,
              case .array(let tools)? = object["tools"] else {
            return result
        }
        var replaced = false
        var rewritten: [JSONValue] = []
        rewritten.reserveCapacity(tools.count + 1)
        for tool in tools {
            guard case .object(let toolObject) = tool,
                  case .string(let name)? = toolObject["name"],
                  name == toolName else {
                rewritten.append(tool)
                continue
            }
            if !replaced {
                rewritten.append(descriptor)
                replaced = true
            }
        }
        if !replaced {
            rewritten.append(descriptor)
        }
        object["tools"] = .array(rewritten)
        return .object(object)
    }

    private static func removingDocumentationSearch(from result: JSONValue) -> JSONValue {
        guard case .object(var object) = result,
              case .array(let tools)? = object["tools"] else {
            return result
        }
        object["tools"] = .array(tools.filter { tool in
            guard case .object(let toolObject) = tool,
                  case .string(let name)? = toolObject["name"] else {
                return true
            }
            return name != toolName
        })
        return .object(object)
    }

    private static func responseErrorTexts(in data: Data) -> [String] {
        var texts = responseErrorObjects(in: data).compactMap { object in
            object["message"] as? String
        }
        texts += responseResultObjects(in: data).flatMap { object -> [String] in
            guard object["isError"] as? Bool == true else {
                return []
            }
            guard let content = object["content"] as? [[String: Any]] else {
                return []
            }
            return content.compactMap { $0["text"] as? String }
        }
        return texts
    }

    private static func responseErrorObjects(in data: Data) -> [[String: Any]] {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        if let object = payload as? [String: Any],
           let error = object["error"] as? [String: Any] {
            return [error]
        }
        guard let array = payload as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            return object["error"] as? [String: Any]
        }
    }

    private static func responseResultObjects(in data: Data) -> [[String: Any]] {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        if let object = payload as? [String: Any],
           let result = object["result"] as? [String: Any] {
            return [result]
        }
        guard let array = payload as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            return object["result"] as? [String: Any]
        }
    }
}

package struct DocumentationProviderTarget: Sendable, Equatable {
    package let processID: pid_t
    package let appPath: String
    package let developerDir: String
    package let mcpbridgePath: String

    package init(
        processID: pid_t,
        appPath: String,
        developerDir: String,
        mcpbridgePath: String
    ) {
        self.processID = processID
        self.appPath = appPath
        self.developerDir = developerDir
        self.mcpbridgePath = mcpbridgePath
    }
}

package protocol XcodeTargetDiscovering: Sendable {
    func runningXcodeTargets() -> [DocumentationProviderTarget]
}

package struct LiveXcodeTargetDiscovery: XcodeTargetDiscovering {
    package init() {}

    package func runningXcodeTargets() -> [DocumentationProviderTarget] {
        var targetsByPID: [pid_t: DocumentationProviderTarget] = [:]

        for application in NSWorkspace.shared.runningApplications {
            guard application.bundleIdentifier == "com.apple.dt.Xcode",
                  application.isTerminated == false,
                  let bundlePath = application.bundleURL?.path else {
                continue
            }
            if let target = Self.target(processID: application.processIdentifier, appPath: bundlePath) {
                targetsByPID[target.processID] = target
            }
        }

        for processID in Self.runningProcessIDs(named: "Xcode") {
            if targetsByPID[processID] != nil {
                continue
            }
            guard let processPath = Self.processPath(processID: processID),
                  let appPath = Self.appPath(fromExecutablePath: processPath),
                  let target = Self.target(processID: processID, appPath: appPath) else {
                continue
            }
            targetsByPID[target.processID] = target
        }

        return targetsByPID.values.sorted { lhs, rhs in
            if lhs.appPath == rhs.appPath {
                return lhs.processID < rhs.processID
            }
            return lhs.appPath < rhs.appPath
        }
    }

    private static func target(processID: pid_t, appPath: String) -> DocumentationProviderTarget? {
        let developerDir = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Developer")
            .path
        let mcpbridgePath = URL(fileURLWithPath: developerDir)
            .appendingPathComponent("usr/bin/mcpbridge")
            .path
        guard FileManager.default.isExecutableFile(atPath: mcpbridgePath) else {
            return nil
        }
        return DocumentationProviderTarget(
            processID: processID,
            appPath: appPath,
            developerDir: developerDir,
            mcpbridgePath: mcpbridgePath
        )
    }

    private static func appPath(fromExecutablePath path: String) -> String? {
        guard let range = path.range(of: "/Contents/MacOS/Xcode") else {
            return nil
        }
        return String(path[..<range.lowerBound])
    }

    private static func processPath(processID: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro does not import.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = unsafe proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return unsafe buffer.withUnsafeBufferPointer { pointer in
            unsafe pointer.baseAddress.map { unsafe String(cString: $0) }
        }
    }

    private static func runningProcessIDs(named processName: String) -> [pid_t] {
        let estimatedByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimatedByteCount > 0 else {
            return []
        }
        var pids = [pid_t](
            repeating: 0,
            count: Int(estimatedByteCount) / MemoryLayout<pid_t>.size + 32
        )
        let byteCount = unsafe pids.withUnsafeMutableBufferPointer { buffer in
            unsafe proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard byteCount > 0 else {
            return []
        }
        var result: [pid_t] = []
        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) where pid > 0 {
            var nameBuffer = [CChar](repeating: 0, count: 64)
            let nameLength = unsafe proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            guard nameLength > 0 else {
                continue
            }
            let name = unsafe nameBuffer.withUnsafeBufferPointer { pointer in
                unsafe pointer.baseAddress.map { unsafe String(cString: $0) }
            }
            if name == processName {
                result.append(pid)
            }
        }
        return result
    }
}

package protocol DocumentationProviderSessionMaking: Sendable {
    func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession
}

package struct LiveDocumentationProviderSessionFactory: DocumentationProviderSessionMaking {
    private let baseEnvironment: [String: String]

    package init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    package func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession {
        var environment = baseEnvironment
        environment.removeValue(forKey: "XCODE_PID")
        environment["MCP_XCODE_PID"] = String(target.processID)
        environment["DEVELOPER_DIR"] = target.developerDir
        let config = UpstreamProcess.Config(
            command: target.mcpbridgePath,
            args: [],
            environment: environment,
            maxQueuedWriteBytes: 4 * 1_048_576
        )
        return try await UpstreamProcess(config: config).startSession()
    }
}

private final class DocumentationPendingResponse: @unchecked Sendable {
    let originalID: RPCID
    let continuation: CheckedContinuation<Data, Error>
    var timeoutTask: Task<Void, Never>?

    init(originalID: RPCID, continuation: CheckedContinuation<Data, Error>) {
        self.originalID = originalID
        self.continuation = continuation
    }
}

package actor DocumentationProviderConnection {
    private let session: any UpstreamSession
    private var eventTask: Task<Void, Never>?
    private var pendingResponses: [String: DocumentationPendingResponse] = [:]
    private var nextID: Int64 = 1

    package init(session: any UpstreamSession) {
        self.session = session
    }

    package func start() {
        guard eventTask == nil else { return }
        let session = session
        eventTask = Task { [weak self, session] in
            for await event in session.events {
                await self?.handle(event)
            }
            await self?.failAll(UpstreamSlotAcquisitionError.unavailable)
        }
    }

    package func stop() async {
        eventTask?.cancel()
        eventTask = nil
        failAll(CancellationError())
        await session.stop()
    }

    package func sendNotification(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ControlPlaneError.invalidResponse("invalid notification")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let result = await session.send(data)
        guard result == .accepted else {
            throw UpstreamSlotAcquisitionError.unavailable
        }
    }

    package func call(_ requestData: Data, timeout: TimeAmount?) async throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: requestData, options: [])
            as? [String: Any],
            let originalIDValue = object["id"],
            let originalID = RPCID(any: originalIDValue) else {
            throw ControlPlaneError.invalidResponse("missing DocumentationSearch request id")
        }

        let upstreamID = nextID
        let upstreamIDKey = String(upstreamID)
        nextID += 1
        object["id"] = upstreamID
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ControlPlaneError.invalidResponse("invalid DocumentationSearch request")
        }
        let upstreamData = try JSONSerialization.data(withJSONObject: object, options: [])

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = DocumentationPendingResponse(
                    originalID: originalID,
                    continuation: continuation
                )
                pendingResponses[upstreamIDKey] = pending
                scheduleTimeoutIfNeeded(id: upstreamIDKey, timeout: timeout, pending: pending)

                Task { [weak self, session] in
                    let sendResult = await session.send(upstreamData)
                    guard sendResult == .accepted else {
                        await self?.failPending(id: upstreamIDKey, error: UpstreamSlotAcquisitionError.unavailable)
                        return
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPending(id: upstreamIDKey, error: CancellationError())
            }
        }
    }

    private func scheduleTimeoutIfNeeded(
        id: String,
        timeout: TimeAmount?,
        pending: DocumentationPendingResponse
    ) {
        guard let timeout, timeout.nanoseconds > 0 else {
            return
        }
        let nanoseconds = UInt64(timeout.nanoseconds)
        pending.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.failPending(id: id, error: TimeoutError())
        }
    }

    private func handle(_ event: UpstreamEvent) {
        switch event {
        case .message(let data):
            handleMessage(data)
        case .exit, .stdoutProtocolViolation:
            failAll(UpstreamSlotAcquisitionError.unavailable)
        case .stderr, .stdoutBufferSize:
            break
        }
    }

    private func handleMessage(_ data: Data) {
        guard var object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let responseIDValue = object["id"],
              let responseID = RPCID(any: responseIDValue),
              let pending = pendingResponses.removeValue(forKey: responseID.key) else {
            return
        }

        pending.timeoutTask?.cancel()
        object["id"] = pending.originalID.value.foundationObject
        guard JSONSerialization.isValidJSONObject(object),
              let rewrittenData = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            pending.continuation.resume(throwing: ControlPlaneError.invalidResponse("invalid DocumentationSearch response"))
            return
        }
        pending.continuation.resume(returning: rewrittenData)
    }

    private func failPending(id: String, error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        for item in pending.values {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: error)
        }
    }
}

package actor DocumentationProviderManager: DocumentationProviderManaging {
    private struct CandidateProfile: Sendable {
        let id: UUID
        let target: DocumentationProviderTarget
        let connection: DocumentationProviderConnection
        let descriptor: JSONValue
        let toolCount: Int
        let serverVersion: String
    }

    private struct ActiveProvider: Sendable {
        let profile: CandidateProfile
    }

    private struct ProviderSelection: Sendable {
        let id: UUID
        let task: Task<CandidateProfile?, Never>
    }

    private enum ProviderSelectionWaitResult: Sendable {
        case completed(CandidateProfile?)
        case timedOut
    }

    private final class ProviderSelectionWaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProviderSelectionWaitResult, Never>?
        private var resolvedResult: ProviderSelectionWaitResult?

        func setContinuation(_ continuation: CheckedContinuation<ProviderSelectionWaitResult, Never>) {
            lock.lock()
            if let resolvedResult {
                lock.unlock()
                continuation.resume(returning: resolvedResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: ProviderSelectionWaitResult) {
            lock.lock()
            guard resolvedResult == nil else {
                lock.unlock()
                return
            }
            resolvedResult = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    private let discovery: any XcodeTargetDiscovering
    private let sessionFactory: any DocumentationProviderSessionMaking
    private let providerSelectionTimeout: TimeAmount?
    private let pinnedProcessID: pid_t?
    private let initializeParams: [String: JSONValue]
    private let clock: ClockClient
    private let logger: Logger
    private var activeProvider: ActiveProvider?
    private var providerSelection: ProviderSelection?
    private var isShutdown = false

    package init(
        discovery: any XcodeTargetDiscovering = LiveXcodeTargetDiscovery(),
        sessionFactory: any DocumentationProviderSessionMaking = LiveDocumentationProviderSessionFactory(),
        providerSelectionTimeout: TimeAmount? = .seconds(30),
        pinnedProcessID: pid_t? = nil,
        initializeParams: [String: JSONValue] = InitializeHandshakeParams.defaultParams(),
        clock: ClockClient = .liveValue,
        logger: Logger = ProxyLogging.make("documentation.provider")
    ) {
        self.discovery = discovery
        self.sessionFactory = sessionFactory
        self.providerSelectionTimeout = providerSelectionTimeout
        self.pinnedProcessID = pinnedProcessID
        self.initializeParams = initializeParams
        self.clock = clock
        self.logger = logger
    }

    package func prewarm(requestTimeout: TimeAmount?) async -> DocumentationToolListUpdate {
        guard !isShutdown else { return .unavailable }
        return await toolListUpdate(requestTimeout: requestTimeout)
    }

    package func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationToolListUpdate {
        guard !isShutdown else {
            return .unavailable
        }
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        guard !Task.isCancelled else {
            return .unavailable
        }
        guard let provider = await providerIfAvailable(requestTimeout: requestTimeout) else {
            return .unavailable
        }
        return .available(provider.profile.descriptor)
    }

    package func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProviderCallOutcome {
        guard !isShutdown else {
            return .noProvider
        }
        let deadline = Deadline.fromNow(requestTimeoutOverride, clock: clock)
        // Each attempt: acquire provider, call, classify. A failed call or a
        // "not enabled" response invalidates the provider and retries once
        // with a replacement; the most recent classification wins.
        var lastOutcome: DocumentationProviderCallOutcome?
        var deadlineExpired = false

        for _ in 0..<2 {
            if let deadline, deadline.hasExpired {
                deadlineExpired = true
                break
            }
            guard let provider = await providerIfAvailable(requestTimeout: deadline?.remaining()) else {
                try Task.checkCancellation()
                break
            }
            if let deadline, deadline.hasExpired {
                deadlineExpired = true
                break
            }
            do {
                let response = try await provider.profile.connection.call(
                    requestData,
                    timeout: deadline?.remaining()
                )
                guard DocumentationToolCatalog.responseIsDocumentationNotEnabled(response) else {
                    return .handled(response)
                }
                await invalidate(provider, reason: "documentation_search_not_enabled")
                try Task.checkCancellation()
                lastOutcome = .handled(response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                await invalidate(provider, reason: "documentation_provider_call_failed")
                lastOutcome = .failed(error)
            }
        }

        if let lastOutcome {
            if case .failed(let error) = lastOutcome, error is UpstreamSlotAcquisitionError {
                // The provider channel itself is gone; treat it like having
                // no provider so the caller forwards to the regular upstream.
                return .noProvider
            }
            return lastOutcome
        }
        if deadlineExpired {
            return .failed(TimeoutError())
        }
        return .noProvider
    }

    package func invalidate(reason _: String) async {
        let selection = providerSelection
        providerSelection = nil
        selection?.task.cancel()
        let provider = activeProvider
        activeProvider = nil
        if let selected = await selection?.task.value,
           selected.id != provider?.profile.id {
            await selected.connection.stop()
        }
        await provider?.profile.connection.stop()
    }

    package func shutdown() async {
        isShutdown = true
        await invalidate(reason: "shutdown")
    }

    private func providerIfAvailable(requestTimeout: TimeAmount?) async -> ActiveProvider? {
        guard !isShutdown else {
            return nil
        }
        if let activeProvider {
            return activeProvider
        }
        let selection: ProviderSelection
        if let providerSelection {
            selection = providerSelection
        } else {
            let selectionTimeout = providerSelectionTimeout
            selection = ProviderSelection(
                id: UUID(),
                task: Task { await self.selectProvider(requestTimeout: selectionTimeout) }
            )
            providerSelection = selection
        }

        let waitResult = await waitForSelection(selection, requestTimeout: requestTimeout)
        let selected: CandidateProfile?
        switch waitResult {
        case .completed(let profile):
            selected = profile
        case .timedOut:
            return nil
        }
        let selectionIsCurrent = providerSelection?.id == selection.id
        if selectionIsCurrent {
            providerSelection = nil
        }

        if isShutdown {
            if let selected {
                await selected.connection.stop()
            }
            return nil
        }

        if let activeProvider {
            if let selected, selected.id != activeProvider.profile.id {
                await selected.connection.stop()
            }
            return activeProvider
        }

        guard selectionIsCurrent else {
            if let selected {
                await selected.connection.stop()
            }
            return nil
        }
        guard let selected else {
            return nil
        }
        let provider = ActiveProvider(profile: selected)
        activeProvider = provider
        return provider
    }

    private func waitForSelection(
        _ selection: ProviderSelection,
        requestTimeout: TimeAmount?
    ) async -> ProviderSelectionWaitResult {
        guard !Task.isCancelled else {
            return .timedOut
        }

        let state = ProviderSelectionWaitState()
        let selectionWaitTask = Task {
            let profile = await selection.task.value
            state.resume(.completed(profile))
        }
        let timeoutTask: Task<Void, Never>?
        if let requestTimeout, requestTimeout.nanoseconds > 0 {
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(requestTimeout.nanoseconds))
                state.resume(.timedOut)
            }
        } else {
            timeoutTask = nil
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.setContinuation(continuation)
            }
        } onCancel: {
            state.resume(.timedOut)
        }
        selectionWaitTask.cancel()
        timeoutTask?.cancel()
        return result
    }

    private func invalidate(_ provider: ActiveProvider, reason _: String) async {
        guard let activeProvider, activeProvider.profile.id == provider.profile.id else {
            await provider.profile.connection.stop()
            return
        }
        self.activeProvider = nil
        await provider.profile.connection.stop()
    }

    private func selectProvider(requestTimeout: TimeAmount?) async -> CandidateProfile? {
        guard !isShutdown else {
            return nil
        }
        let selectionDeadline = Deadline.fromNow(requestTimeout, clock: clock)
        let discoveredTargets = discovery.runningXcodeTargets()
        let targets: [DocumentationProviderTarget]
        if let pinnedProcessID {
            targets = discoveredTargets.filter { $0.processID == pinnedProcessID }
        } else {
            targets = discoveredTargets
        }
        logger.debug(
            "Selecting documentation provider from running Xcode processes",
            metadata: [
                "candidate_count": .string("\(targets.count)"),
                "discovered_candidate_count": .string("\(discoveredTargets.count)"),
                "pinned_pid": .string(pinnedProcessID.map(String.init) ?? ""),
                "candidates": .string(targets.map { "\($0.processID):\($0.appPath)" }.joined(separator: ",")),
            ]
        )
        var profiles: [CandidateProfile] = []
        for (index, target) in targets.enumerated() {
            guard !Task.isCancelled, !isShutdown else {
                break
            }
            let candidateTimeout = candidateProbeTimeout(
                until: selectionDeadline,
                remainingCandidateCount: targets.count - index
            )
            if candidateTimeout?.nanoseconds == 0 {
                break
            }
            do {
                let profile = try await boundedProbe(target: target, requestTimeout: candidateTimeout)
                guard !Task.isCancelled, !isShutdown else {
                    await profile.connection.stop()
                    break
                }
                profiles.append(profile)
            } catch is CancellationError {
                break
            } catch {
                logger.debug(
                    "Documentation provider candidate rejected",
                    metadata: [
                        "pid": .string("\(target.processID)"),
                        "app_path": .string(target.appPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                continue
            }
        }

        if Task.isCancelled || isShutdown {
            for profile in profiles {
                await profile.connection.stop()
            }
            return nil
        }

        guard let selected = profiles.max(by: { lhs, rhs in
            if lhs.toolCount != rhs.toolCount {
                return lhs.toolCount < rhs.toolCount
            }
            return Self.compareVersion(lhs.serverVersion, rhs.serverVersion) == .orderedAscending
        }) else {
            return nil
        }

        for profile in profiles where profile.target != selected.target {
            await profile.connection.stop()
        }
        logger.info(
            "Selected documentation provider",
            metadata: [
                "pid": .string("\(selected.target.processID)"),
                "app_path": .string(selected.target.appPath),
                "server_version": .string(selected.serverVersion),
                "tool_count": .string("\(selected.toolCount)"),
            ]
        )
        return selected
    }

    private func boundedProbe(
        target: DocumentationProviderTarget,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return try await probe(target: target, requestTimeout: requestTimeout)
        }
        return try await withThrowingTaskGroup(of: CandidateProfile.self) { group in
            group.addTask {
                try await self.probe(target: target, requestTimeout: requestTimeout)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(requestTimeout.nanoseconds))
                throw TimeoutError()
            }
            do {
                guard let result = try await group.next() else {
                    throw UpstreamSlotAcquisitionError.unavailable
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func probe(
        target: DocumentationProviderTarget,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        let probeDeadline = Deadline.fromNow(requestTimeout ?? .seconds(30), clock: clock)
        try Task.checkCancellation()
        let session = try await sessionFactory.startSession(for: target)
        let connection = DocumentationProviderConnection(session: session)
        do {
            try Task.checkCancellation()
            await connection.start()
            let initializeTimeout = remainingTimeout(until: probeDeadline)
            guard initializeTimeout?.nanoseconds != 0 else {
                throw TimeoutError()
            }
            let initialize = try await connection.call(
                try makeInitializeRequestData(),
                timeout: initializeTimeout
            )
            let serverVersion = Self.serverVersion(fromInitializeResponse: initialize) ?? ""
            try Task.checkCancellation()
            try await connection.sendNotification([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ])
            let toolsListTimeout = remainingTimeout(until: probeDeadline)
            guard toolsListTimeout?.nanoseconds != 0 else {
                throw TimeoutError()
            }
            let toolsList = try await connection.call(
                try Self.makeToolsListRequestData(),
                timeout: toolsListTimeout
            )
            let toolsResult = try Self.resultValue(from: toolsList)
            guard let descriptor = DocumentationToolCatalog.descriptor(in: toolsResult) else {
                throw UpstreamSlotAcquisitionError.unavailable
            }
            let documentationProbeTimeout = remainingTimeout(until: probeDeadline)
            guard documentationProbeTimeout?.nanoseconds != 0 else {
                throw TimeoutError()
            }
            let probeResponse = try await connection.call(
                try Self.makeDocumentationProbeRequestData(),
                timeout: documentationProbeTimeout
            )
            guard !DocumentationToolCatalog.responseIsDocumentationNotEnabled(probeResponse),
                  !DocumentationToolCatalog.responseIsToolError(probeResponse) else {
                throw UpstreamSlotAcquisitionError.unavailable
            }
            return CandidateProfile(
                id: UUID(),
                target: target,
                connection: connection,
                descriptor: descriptor,
                toolCount: Self.toolCount(in: toolsResult),
                serverVersion: serverVersion
            )
        } catch {
            await connection.stop()
            throw error
        }
    }

    private func makeInitializeRequestData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "initialize",
                "method": "initialize",
                "params": initializeParams.mapValues(\.foundationObject),
            ],
            options: []
        )
    }

    private static func makeToolsListRequestData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "tools-list",
                "method": "tools/list",
            ],
            options: []
        )
    }

    private static func makeDocumentationProbeRequestData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "documentation-probe",
                "method": "tools/call",
                "params": [
                    "name": DocumentationToolCatalog.toolName,
                    "arguments": [
                        "query": "UIView animate withDuration animations completion",
                    ],
                ],
            ],
            options: []
        )
    }

    private static func resultValue(from responseData: Data) throws -> JSONValue {
        guard let object = try JSONSerialization.jsonObject(with: responseData, options: [])
            as? [String: Any],
            let result = object["result"],
            let value = JSONValue(any: result) else {
            throw ControlPlaneError.invalidResponse("invalid documentation provider response")
        }
        return value
    }

    private static func toolCount(in result: JSONValue) -> Int {
        guard case .object(let object) = result,
              case .array(let tools)? = object["tools"] else {
            return 0
        }
        return tools.count
    }

    private static func serverVersion(fromInitializeResponse data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [])
            as? [String: Any],
            let result = object["result"] as? [String: Any],
            let serverInfo = result["serverInfo"] as? [String: Any] else {
            return nil
        }
        return serverInfo["version"] as? String
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericVersionParts(lhs)
        let rhsParts = numericVersionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func numericVersionParts(_ version: String) -> [Int] {
        version
            .split { character in
                !character.isNumber
            }
            .compactMap { Int($0) }
    }

    private func remainingTimeout(until deadline: Deadline?) -> TimeAmount? {
        guard let deadline else {
            return nil
        }
        return deadline.remaining()
    }

    private func candidateProbeTimeout(
        until deadline: Deadline?,
        remainingCandidateCount: Int
    ) -> TimeAmount? {
        guard let remaining = remainingTimeout(until: deadline) else {
            return nil
        }
        guard remaining.nanoseconds > 0 else {
            return .nanoseconds(0)
        }
        let divisor = max(Int64(remainingCandidateCount), 1)
        return .nanoseconds(max(remaining.nanoseconds / divisor, 1))
    }
}
