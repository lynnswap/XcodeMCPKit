import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP

package enum DocumentationProvider {}

extension DocumentationProvider {
    package enum ToolListUpdate: Sendable {
        case unchanged
        case unavailable
        case available(JSONValue)

        package var debugLabel: String {
            switch self {
            case .unchanged:
                "unchanged"
            case .unavailable:
                "unavailable"
            case .available:
                "available"
            }
        }
    }
}

extension DocumentationProvider {
    package enum UnavailableReason: Sendable, Error, CustomStringConvertible {
        case noAvailableProvider

        package static let userFacingMessage =
            "DocumentationSearch is unavailable from the running Xcode documentation provider. Try restarting Xcode if the problem persists."

        package var message: String {
            switch self {
            case .noAvailableProvider:
                Self.userFacingMessage
            }
        }

        package var description: String {
            message
        }
    }
}

/// The manager's classification of one DocumentationSearch attempt.
/// When the manager is enabled, DocumentationSearch is owned by the
/// documentation provider and does not fall back to the regular upstream.
extension DocumentationProvider {
    package enum CallOutcome: Sendable {
        case handled(Data, invalidatedProvider: Bool)
        case unavailable(DocumentationProvider.UnavailableReason)
        case failed(any Error, invalidatedProvider: Bool)
    }
}

package protocol DocumentationProviderManaging: Sendable {
    func startBackgroundDiscovery(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate
    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome
    func invalidate(reason: String) async
    func shutdown() async
}

extension DocumentationProvider {
    package enum ToolCatalog {
        package static let toolName = "DocumentationSearch"

        package static func applying(
            _ update: DocumentationProvider.ToolListUpdate,
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
                case .array(let tools)? = object["tools"]
            else {
                return nil
            }
            return tools.first { value in
                guard case .object(let toolObject) = value,
                    case .string(let name)? = toolObject["name"]
                else {
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

        private static func replacingDocumentationSearch(
            in result: JSONValue,
            with descriptor: JSONValue
        ) -> JSONValue {
            guard case .object(var object) = result,
                case .array(let tools)? = object["tools"]
            else {
                return result
            }
            var replaced = false
            var rewritten: [JSONValue] = []
            rewritten.reserveCapacity(tools.count + 1)
            for tool in tools {
                guard case .object(let toolObject) = tool,
                    case .string(let name)? = toolObject["name"],
                    name == toolName
                else {
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
                case .array(let tools)? = object["tools"]
            else {
                return result
            }
            object["tools"] = .array(
                tools.filter { tool in
                    guard case .object(let toolObject) = tool,
                        case .string(let name)? = toolObject["name"]
                    else {
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
                let error = object["error"] as? [String: Any]
            {
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
                let result = object["result"] as? [String: Any]
            {
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
}

package protocol DocumentationProviderSessionMaking: Sendable {
    func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession
}

package struct LiveDocumentationProviderSessionFactory: DocumentationProviderSessionMaking {
    private let baseEnvironment: [String: String]

    package init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    package func startSession(for target: DocumentationProviderTarget) async throws
        -> any UpstreamSession
    {
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
    let originalID: JSONRPC.ID
    let continuation: CheckedContinuation<Data, Error>
    var timeoutTask: Task<Void, Never>?

    init(originalID: JSONRPC.ID, continuation: CheckedContinuation<Data, Error>) {
        self.originalID = originalID
        self.continuation = continuation
    }
}

package actor DocumentationProviderConnection {
    private let session: any UpstreamSession
    private let clock: ClockClient
    private var eventTask: Task<Void, Never>?
    private var pendingResponses: [String: DocumentationPendingResponse] = [:]
    private var nextID: Int64 = 1

    package init(session: any UpstreamSession, clock: ClockClient = .liveValue) {
        self.session = session
        self.clock = clock
    }

    package func start() {
        guard eventTask == nil else { return }
        let session = session
        eventTask = Task { [weak self, session] in
            for await event in session.events {
                await self?.handle(event)
            }
            await self?.failAll(UpstreamSlotScheduler.AcquisitionError.unavailable)
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
            throw ControlPlane.Error.invalidResponse("invalid notification")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let result = await session.send(data)
        guard result == .accepted else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    package func call(_ requestData: Data, timeout: TimeAmount?) async throws -> Data {
        guard
            var object = try JSONSerialization.jsonObject(with: requestData, options: [])
                as? [String: Any],
            let originalID = JSONRPC.Message.Inspector.requestID(from: object)
        else {
            throw ControlPlane.Error.invalidResponse("missing DocumentationSearch request id")
        }

        let upstreamID = nextID
        let upstreamIDKey = String(upstreamID)
        nextID += 1
        object["id"] = upstreamID
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ControlPlane.Error.invalidResponse("invalid DocumentationSearch request")
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
                        await self?.failPending(
                            id: upstreamIDKey,
                            error: UpstreamSlotScheduler.AcquisitionError.unavailable)
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
        pending.timeoutTask = Task { [weak self, clock] in
            await clock.sleep(.nanoseconds(timeout.nanoseconds))
            guard Task.isCancelled == false else {
                return
            }
            await self?.failPending(id: id, error: TimeoutError())
        }
    }

    private func handle(_ event: Upstream.Event) {
        switch event {
        case .message(let data):
            handleMessage(data)
        case .exit, .stdoutProtocolViolation:
            failAll(UpstreamSlotScheduler.AcquisitionError.unavailable)
        case .stderr, .stdoutBufferSize:
            break
        }
    }

    private func handleMessage(_ data: Data) {
        guard
            var object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let responseID = JSONRPC.Message.Inspector.responseID(from: object),
            let pending = pendingResponses.removeValue(forKey: responseID.key)
        else {
            return
        }

        pending.timeoutTask?.cancel()
        object["id"] = pending.originalID.value.foundationObject
        guard JSONSerialization.isValidJSONObject(object),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            pending.continuation.resume(
                throwing: ControlPlane.Error.invalidResponse("invalid DocumentationSearch response")
            )
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
        var descriptor: JSONValue?
        let serverVersion: String
    }

    private struct ActiveProvider: Sendable {
        let profile: CandidateProfile
    }

    private struct ProviderPreparation: Sendable {
        let task: Task<CandidateProfile, Error>
    }

    private struct PreparationWaitTimedOut: Error {}

    private final class PreparationWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CandidateProfile, Error>?
        private var tasks: [Task<Void, Never>] = []
        private var resolved = false

        func setContinuation(_ continuation: CheckedContinuation<CandidateProfile, Error>) {
            lock.lock()
            if resolved {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func addTask(_ task: Task<Void, Never>) {
            lock.lock()
            if resolved {
                lock.unlock()
                task.cancel()
                return
            }
            tasks.append(task)
            lock.unlock()
        }

        func resume(_ result: Result<CandidateProfile, Error>) {
            lock.lock()
            guard resolved == false else {
                lock.unlock()
                return
            }
            resolved = true
            let continuation = continuation
            self.continuation = nil
            let tasks = tasks
            self.tasks.removeAll()
            lock.unlock()

            for task in tasks {
                task.cancel()
            }
            switch result {
            case .success(let profile):
                continuation?.resume(returning: profile)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
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
    private var preparedProviders: [pid_t: CandidateProfile] = [:]
    private var providerPreparations: [pid_t: ProviderPreparation] = [:]
    private var unusableProcessIDs: Set<pid_t> = []
    private var isShutdown = false

    package init(
        discovery: any XcodeTargetDiscovering,
        sessionFactory: any DocumentationProviderSessionMaking =
            LiveDocumentationProviderSessionFactory(),
        providerSelectionTimeout: TimeAmount? = .seconds(30),
        pinnedProcessID: pid_t? = nil,
        initializeParams: [String: JSONValue] = InitializeHandshakeJSON.defaultParams(),
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

    package func startBackgroundDiscovery(requestTimeout: TimeAmount?) async
        -> DocumentationProvider.ToolListUpdate
    {
        guard !isShutdown else { return .unavailable }
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        let deadline = Deadline.fromNow(requestTimeout, clock: clock)
        let targets = orderedTargets(excluding: [])
        guard targets.isEmpty == false else {
            return .unavailable
        }
        for target in targets {
            guard !Task.isCancelled, !isShutdown else {
                return .unavailable
            }
            guard unusableProcessIDs.contains(target.processID) == false else {
                continue
            }
            do {
                let profile = try await preparedProvider(
                    for: target,
                    requestTimeout: remainingTimeout(until: deadline),
                    fetchDescriptor: true
                )
                if let descriptor = profile.descriptor {
                    let didPromote = await promoteToActive(profile)
                    if didPromote {
                        logger.info(
                            "Prewarmed documentation provider",
                            metadata: [
                                "pid": .string("\(target.processID)"),
                                "app_path": .string(target.appPath),
                                "xcode_version": .string(target.xcodeVersion),
                                "server_version": .string(profile.serverVersion),
                            ]
                        )
                    }
                    return .available(descriptor)
                }
                return toolListUpdateFromCachedState(requestTimeout: requestTimeout)
            } catch is CancellationError {
                return .unavailable
            } catch {
                logger.debug(
                    "Documentation provider background discovery candidate rejected",
                    metadata: candidateLogMetadata(target: target, error: error)
                )
                continue
            }
        }
        return toolListUpdateFromCachedState(requestTimeout: requestTimeout)
    }

    package func toolListUpdate(requestTimeout: TimeAmount?) async
        -> DocumentationProvider.ToolListUpdate
    {
        guard !isShutdown else {
            return .unavailable
        }
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        guard !Task.isCancelled else {
            return .unavailable
        }
        return toolListUpdateFromCachedState(requestTimeout: requestTimeout)
    }

    private func toolListUpdateFromCachedState(requestTimeout: TimeAmount?)
        -> DocumentationProvider.ToolListUpdate
    {
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        if let activeProvider {
            guard let descriptor = activeProvider.profile.descriptor else {
                return .unchanged
            }
            return .available(descriptor)
        }
        let targets = orderedTargets(excluding: [])
        guard targets.isEmpty == false else {
            return .unavailable
        }
        for target in targets {
            if let descriptor = preparedProviders[target.processID]?.descriptor {
                return .available(descriptor)
            }
        }
        let targetIDs = Set(targets.map(\.processID))
        if targetIDs.isSubset(of: unusableProcessIDs) {
            return .unavailable
        }
        return .unchanged
    }

    package func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome {
        guard !isShutdown else {
            return .unavailable(.noAvailableProvider)
        }
        let deadline = Deadline.fromNow(requestTimeoutOverride, clock: clock)
        var rejectedProcessIDs: Set<pid_t> = []
        var invalidatedProvider = false

        while !Task.isCancelled {
            if let deadline, deadline.hasExpired {
                return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
            }
            if let activeProvider,
                rejectedProcessIDs.contains(activeProvider.profile.target.processID) == false,
                activeProviderIsCurrentBest(
                    activeProvider,
                    excluding: rejectedProcessIDs.union(unusableProcessIDs)
                )
            {
                let fallbackTargets = orderedTargets(
                    excluding: rejectedProcessIDs
                        .union(unusableProcessIDs)
                        .union([activeProvider.profile.target.processID])
                )
                let activeDeadline = makeDeadline(
                    fromTimeout: timeoutForCandidate(
                        until: deadline,
                        remainingCandidateCount: fallbackTargets.count + 1
                    )
                )
                switch try await attemptDocumentationSearch(
                    requestData: requestData,
                    provider: activeProvider,
                    deadline: activeDeadline
                ) {
                case .success(let data):
                    return .handled(data, invalidatedProvider: invalidatedProvider)
                case .rejected(let processID, let permanentlyUnusable):
                    rejectedProcessIDs.insert(processID)
                    invalidatedProvider = true
                    if permanentlyUnusable {
                        unusableProcessIDs.insert(processID)
                    }
                    continue
                case .failed(let error):
                    if let deadline, deadline.hasExpired {
                        return .failed(error, invalidatedProvider: invalidatedProvider)
                    }
                    rejectedProcessIDs.insert(activeProvider.profile.target.processID)
                    invalidatedProvider = true
                    continue
                }
            }

            let targets = orderedTargets(
                excluding: rejectedProcessIDs.union(unusableProcessIDs)
            )
            guard targets.isEmpty == false else {
                try Task.checkCancellation()
                if let deadline, deadline.hasExpired {
                    return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
                }
                return .unavailable(.noAvailableProvider)
            }

            var progressed = false
            for (index, target) in targets.enumerated() {
                if let deadline, deadline.hasExpired {
                    return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
                }
                let candidateDeadline = makeDeadline(
                    fromTimeout: timeoutForCandidate(
                        until: deadline,
                        remainingCandidateCount: targets.count - index
                    )
                )
                do {
                    let profile = try await preparedProvider(
                        for: target,
                        requestTimeout: remainingTimeout(until: candidateDeadline),
                        fetchDescriptor: false
                    )
                    let provider = ActiveProvider(profile: profile)
                    switch try await attemptDocumentationSearch(
                        requestData: requestData,
                        provider: provider,
                        deadline: candidateDeadline
                    ) {
                    case .success(let data):
                        let didPromote = await promoteToActive(profile)
                        if didPromote {
                            logger.info(
                                "Selected documentation provider",
                                metadata: [
                                    "pid": .string("\(target.processID)"),
                                    "app_path": .string(target.appPath),
                                    "xcode_version": .string(target.xcodeVersion),
                                    "server_version": .string(profile.serverVersion),
                                ]
                            )
                        }
                        return .handled(data, invalidatedProvider: invalidatedProvider)
                    case .rejected(let processID, let permanentlyUnusable):
                        rejectedProcessIDs.insert(processID)
                        invalidatedProvider = true
                        progressed = true
                        if permanentlyUnusable {
                            unusableProcessIDs.insert(processID)
                        }
                        continue
                    case .failed(let error):
                        rejectedProcessIDs.insert(target.processID)
                        invalidatedProvider = true
                        progressed = true
                        if let deadline, deadline.hasExpired {
                            return .failed(error, invalidatedProvider: invalidatedProvider)
                        }
                        continue
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    rejectedProcessIDs.insert(target.processID)
                    invalidatedProvider = true
                    progressed = true
                    if let deadline, deadline.hasExpired {
                        return .failed(error, invalidatedProvider: invalidatedProvider)
                    }
                    logger.debug(
                        "Documentation provider candidate rejected before user request",
                        metadata: candidateLogMetadata(target: target, error: error)
                    )
                }
            }
            if !progressed {
                return .unavailable(.noAvailableProvider)
            }
        }
        throw CancellationError()
    }

    private func activeProviderIsCurrentBest(
        _ activeProvider: ActiveProvider,
        excluding excludedProcessIDs: Set<pid_t>
    ) -> Bool {
        guard let first = orderedTargets(excluding: excludedProcessIDs).first else {
            return false
        }
        return first.processID == activeProvider.profile.target.processID
    }

    private func promoteToActive(_ profile: CandidateProfile) async -> Bool {
        let previous = activeProvider
        activeProvider = ActiveProvider(profile: profile)
        preparedProviders.removeValue(forKey: profile.target.processID)
        guard let previous else {
            return true
        }
        guard previous.profile.id != profile.id else {
            return false
        }
        await previous.profile.connection.stop()
        return true
    }

    private enum DocumentationAttemptResult: Sendable {
        case success(Data)
        case rejected(processID: pid_t, permanentlyUnusable: Bool)
        case failed(any Error)
    }

    private func attemptDocumentationSearch(
        requestData: Data,
        provider: ActiveProvider,
        deadline: Deadline?
    ) async throws -> DocumentationAttemptResult {
        let processID = provider.profile.target.processID
        do {
            let response = try await provider.profile.connection.call(
                requestData,
                timeout: remainingTimeout(until: deadline)
            )
            guard !DocumentationProvider.ToolCatalog.responseIsDocumentationNotEnabled(response)
            else {
                await invalidate(provider, reason: "documentation_search_tool_error")
                return .rejected(processID: processID, permanentlyUnusable: true)
            }
            return .success(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await invalidate(provider, reason: "documentation_provider_call_failed")
            return .failed(error)
        }
    }

    package func invalidate(reason _: String) async {
        let preparations = providerPreparations
        providerPreparations.removeAll()
        for preparation in preparations.values {
            preparation.task.cancel()
        }
        let prepared = preparedProviders
        preparedProviders.removeAll()
        let provider = activeProvider
        activeProvider = nil
        for profile in prepared.values where profile.id != provider?.profile.id {
            await profile.connection.stop()
        }
        await provider?.profile.connection.stop()
    }

    package func shutdown() async {
        isShutdown = true
        await invalidate(reason: "shutdown")
    }

    private func preparedProvider(
        for target: DocumentationProviderTarget,
        requestTimeout: TimeAmount?,
        fetchDescriptor: Bool
    ) async throws -> CandidateProfile {
        if let activeProvider, activeProvider.profile.target.processID == target.processID {
            if fetchDescriptor, activeProvider.profile.descriptor == nil {
                let updated = await profileByRefreshingDescriptor(
                    activeProvider.profile,
                    requestTimeout: requestTimeout
                )
                if let current = self.activeProvider,
                    current.profile.id == updated.id
                {
                    let merged = profileByPreferringDescriptor(
                        primary: current.profile,
                        fallback: updated
                    )
                    self.activeProvider = ActiveProvider(profile: merged)
                    return merged
                }
                return updated
            }
            return activeProvider.profile
        }
        if var prepared = preparedProviders[target.processID] {
            if fetchDescriptor, prepared.descriptor == nil {
                let updated = await profileByRefreshingDescriptor(
                    prepared,
                    requestTimeout: requestTimeout
                )
                if let activeProvider, activeProvider.profile.id == updated.id {
                    let merged = profileByPreferringDescriptor(
                        primary: activeProvider.profile,
                        fallback: updated
                    )
                    self.activeProvider = ActiveProvider(profile: merged)
                    return merged
                }
                if let cached = preparedProviders[target.processID],
                    cached.id == updated.id
                {
                    let merged = profileByPreferringDescriptor(
                        primary: cached,
                        fallback: updated
                    )
                    preparedProviders[target.processID] = merged
                    return merged
                }
                prepared = updated
                preparedProviders[target.processID] = prepared
            }
            return prepared
        }
        let preparation: ProviderPreparation
        if let existing = providerPreparations[target.processID] {
            preparation = existing
        } else {
            let timeout = providerSelectionTimeout
            preparation = ProviderPreparation(
                task: Task {
                    try await self.openProviderConnection(
                        target: target,
                        requestTimeout: timeout
                    )
                }
            )
            providerPreparations[target.processID] = preparation
        }
        let profile: CandidateProfile
        do {
            profile = try await waitForPreparation(preparation, requestTimeout: requestTimeout)
        } catch is PreparationWaitTimedOut {
            throw TimeoutError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            providerPreparations.removeValue(forKey: target.processID)
            throw error
        }
        providerPreparations.removeValue(forKey: target.processID)
        if isShutdown {
            await profile.connection.stop()
            throw CancellationError()
        }
        return try await cachePreparedProvider(
            profile,
            requestTimeout: requestTimeout,
            fetchDescriptor: fetchDescriptor
        )
    }

    private func cachePreparedProvider(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?,
        fetchDescriptor: Bool
    ) async throws -> CandidateProfile {
        if let activeProvider, activeProvider.profile.id == profile.id {
            if fetchDescriptor, activeProvider.profile.descriptor == nil {
                let updated = await profileByRefreshingDescriptor(
                    activeProvider.profile,
                    requestTimeout: requestTimeout
                )
                self.activeProvider = ActiveProvider(profile: updated)
                return updated
            }
            return activeProvider.profile
        }
        if let prepared = preparedProviders[profile.target.processID],
            prepared.id == profile.id
        {
            if fetchDescriptor, prepared.descriptor == nil {
                let updated = await profileByRefreshingDescriptor(
                    prepared,
                    requestTimeout: requestTimeout
                )
                preparedProviders[profile.target.processID] = updated
                return updated
            }
            return prepared
        }

        var prepared = profile
        preparedProviders[profile.target.processID] = prepared
        if fetchDescriptor, prepared.descriptor == nil {
            prepared = await profileByRefreshingDescriptor(
                prepared,
                requestTimeout: requestTimeout
            )
            if let activeProvider, activeProvider.profile.id == profile.id {
                let merged = profileByPreferringDescriptor(
                    primary: activeProvider.profile,
                    fallback: prepared
                )
                self.activeProvider = ActiveProvider(profile: merged)
                return merged
            }
            if let cached = preparedProviders[profile.target.processID],
                cached.id == profile.id
            {
                let merged = profileByPreferringDescriptor(primary: cached, fallback: prepared)
                preparedProviders[profile.target.processID] = merged
                return merged
            }
        }

        if let cached = preparedProviders[profile.target.processID],
            cached.id == profile.id
        {
            let merged = profileByPreferringDescriptor(primary: cached, fallback: prepared)
            preparedProviders[profile.target.processID] = merged
            return merged
        }
        preparedProviders[profile.target.processID] = prepared
        return prepared
    }

    private func profileByPreferringDescriptor(
        primary: CandidateProfile,
        fallback: CandidateProfile
    ) -> CandidateProfile {
        guard primary.descriptor == nil, fallback.descriptor != nil else {
            return primary
        }
        var merged = primary
        merged.descriptor = fallback.descriptor
        return merged
    }

    private func waitForPreparation(
        _ preparation: ProviderPreparation,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        guard let requestTimeout else {
            return try await preparation.task.value
        }
        guard requestTimeout.nanoseconds > 0 else {
            throw PreparationWaitTimedOut()
        }
        let waiter = PreparationWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.setContinuation(continuation)
                waiter.addTask(Task {
                    do {
                        let profile = try await preparation.task.value
                        waiter.resume(.success(profile))
                    } catch {
                        waiter.resume(.failure(error))
                    }
                })
                let clock = clock
                waiter.addTask(Task {
                    await clock.sleep(.nanoseconds(requestTimeout.nanoseconds))
                    guard Task.isCancelled == false else {
                        return
                    }
                    waiter.resume(.failure(PreparationWaitTimedOut()))
                })
            }
        } onCancel: {
            waiter.resume(.failure(CancellationError()))
        }
    }

    private func invalidate(_ provider: ActiveProvider, reason _: String) async {
        if let prepared = preparedProviders[provider.profile.target.processID],
            prepared.id == provider.profile.id
        {
            preparedProviders.removeValue(forKey: provider.profile.target.processID)
        }
        if let activeProvider, activeProvider.profile.id == provider.profile.id {
            self.activeProvider = nil
        }
        await provider.profile.connection.stop()
    }

    private func orderedTargets(
        excluding excludedProcessIDs: Set<pid_t>
    ) -> [DocumentationProviderTarget] {
        let discoveredTargets = discovery.runningXcodeTargets()
        let filtered: [DocumentationProviderTarget]
        if let pinnedProcessID {
            filtered = discoveredTargets.filter {
                $0.processID == pinnedProcessID
                    && excludedProcessIDs.contains($0.processID) == false
            }
        } else {
            filtered = discoveredTargets.filter {
                excludedProcessIDs.contains($0.processID) == false
            }
        }
        return filtered.sorted { lhs, rhs in
            let versionComparison = Self.compareVersion(lhs.xcodeVersion, rhs.xcodeVersion)
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }
            if lhs.appPath != rhs.appPath {
                return lhs.appPath < rhs.appPath
            }
            return lhs.processID < rhs.processID
        }
    }

    private func openProviderConnection(
        target: DocumentationProviderTarget,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        guard !isShutdown else {
            throw CancellationError()
        }
        logger.debug(
            "Preparing documentation provider candidate",
            metadata: [
                "pid": .string("\(target.processID)"),
                "app_path": .string(target.appPath),
                "xcode_version": .string(target.xcodeVersion),
            ]
        )
        let startupDeadline = Deadline.fromNow(requestTimeout ?? .seconds(30), clock: clock)
        try Task.checkCancellation()
        let session = try await sessionFactory.startSession(for: target)
        let connection = DocumentationProviderConnection(session: session, clock: clock)
        do {
            try Task.checkCancellation()
            await connection.start()
            let initializeTimeout = remainingTimeout(until: startupDeadline)
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
            let profile = CandidateProfile(
                id: UUID(),
                target: target,
                connection: connection,
                descriptor: nil,
                serverVersion: serverVersion
            )
            return profile
        } catch {
            await connection.stop()
            throw error
        }
    }

    private func profileWithDescriptor(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        var updated = profile
        let toolsListTimeout = requestTimeout
        guard toolsListTimeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        let toolsList = try await profile.connection.call(
            try Self.makeToolsListRequestData(),
            timeout: toolsListTimeout
        )
        let toolsResult = try Self.resultValue(from: toolsList)
        updated.descriptor = DocumentationProvider.ToolCatalog.descriptor(in: toolsResult)
        return updated
    }

    private func profileByRefreshingDescriptor(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?
    ) async -> CandidateProfile {
        do {
            let updated = try await profileWithDescriptor(profile, requestTimeout: requestTimeout)
            if updated.descriptor == nil {
                logger.debug(
                    "Documentation provider descriptor missing from tools/list",
                    metadata: [
                        "pid": .string("\(profile.target.processID)"),
                        "app_path": .string(profile.target.appPath),
                        "xcode_version": .string(profile.target.xcodeVersion),
                    ]
                )
            }
            return updated
        } catch is CancellationError {
            return profile
        } catch {
            logger.debug(
                "Documentation provider descriptor refresh failed",
                metadata: candidateLogMetadata(target: profile.target, error: error)
            )
            return profile
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

    private static func resultValue(from responseData: Data) throws -> JSONValue {
        guard
            let object = try JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"],
            let value = JSONValue(any: result)
        else {
            throw ControlPlane.Error.invalidResponse("invalid documentation provider response")
        }
        return value
    }

    private static func serverVersion(fromInitializeResponse data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let result = object["result"] as? [String: Any],
            let serverInfo = result["serverInfo"] as? [String: Any]
        else {
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

    private func timeoutForCandidate(
        until deadline: Deadline?,
        remainingCandidateCount: Int
    ) -> TimeAmount? {
        guard let remaining = remainingTimeout(until: deadline) else {
            return nil
        }
        guard remaining.nanoseconds > 0 else {
            return .nanoseconds(0)
        }
        guard remainingCandidateCount > 1 else {
            return remaining
        }
        return .nanoseconds(max(1, remaining.nanoseconds / Int64(remainingCandidateCount)))
    }

    private func makeDeadline(fromTimeout timeout: TimeAmount?) -> Deadline? {
        guard let timeout else {
            return nil
        }
        guard timeout.nanoseconds > 0 else {
            return Deadline(uptimeNanoseconds: clock.uptimeNanoseconds(), clock: clock)
        }
        return Deadline.fromNow(timeout, clock: clock)
    }

    private func candidateLogMetadata(
        target: DocumentationProviderTarget,
        error: any Error
    ) -> Logger.Metadata {
        [
            "pid": .string("\(target.processID)"),
            "app_path": .string(target.appPath),
            "xcode_version": .string(target.xcodeVersion),
            "error": .string(String(describing: error)),
        ]
    }
}
