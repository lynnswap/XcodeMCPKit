import AppKit
import Darwin
import Foundation
import NIO
import ProxyCore
import ProxyMCP

package enum DocumentationToolListUpdate: Sendable {
    case unchanged
    case unavailable
    case available(JSONValue)
}

package struct DocumentationProviderCallResult: Sendable {
    package let data: Data
    package let didInvalidateProvider: Bool

    package init(data: Data, didInvalidateProvider: Bool) {
        self.data = data
        self.didInvalidateProvider = didInvalidateProvider
    }
}

package protocol DocumentationProviderManaging: Sendable {
    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationToolListUpdate
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProviderCallResult
    func invalidate(reason: String) async
    func shutdown() async
}

package struct DisabledDocumentationProviderManager: DocumentationProviderManaging {
    package init() {}

    package func toolListUpdate(requestTimeout _: TimeAmount?) async -> DocumentationToolListUpdate {
        .unchanged
    }

    package func callDocumentationSearch(
        requestData _: Data,
        requestTimeoutOverride _: TimeAmount?
    ) async throws -> DocumentationProviderCallResult {
        throw UpstreamSlotAcquisitionError.unavailable
    }

    package func invalidate(reason _: String) async {}
    package func shutdown() async {}
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(processID), "-o", "comm="]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, output.isEmpty == false else {
            return nil
        }
        return output
    }

    private static func runningProcessIDs(named processName: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", processName]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

package protocol DocumentationProviderSessionMaking: Sendable {
    func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession
}

package struct LiveDocumentationProviderSessionFactory: DocumentationProviderSessionMaking {
    package init() {}

    package func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession {
        var environment = ProcessInfo.processInfo.environment
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
        let target: DocumentationProviderTarget
        let connection: DocumentationProviderConnection
        let descriptor: JSONValue
        let toolCount: Int
        let serverVersion: String
    }

    private struct ActiveProvider: Sendable {
        let profile: CandidateProfile
    }

    private let discovery: any XcodeTargetDiscovering
    private let sessionFactory: any DocumentationProviderSessionMaking
    private var activeProvider: ActiveProvider?

    package init(
        discovery: any XcodeTargetDiscovering = LiveXcodeTargetDiscovery(),
        sessionFactory: any DocumentationProviderSessionMaking = LiveDocumentationProviderSessionFactory()
    ) {
        self.discovery = discovery
        self.sessionFactory = sessionFactory
    }

    package func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationToolListUpdate {
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
    ) async throws -> DocumentationProviderCallResult {
        let requestDeadline = Self.requestDeadline(for: requestTimeoutOverride)
        let initialTimeout = Self.requestTimeout(until: requestDeadline)
        guard initialTimeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        guard let provider = await providerIfAvailable(requestTimeout: initialTimeout) else {
            throw UpstreamSlotAcquisitionError.unavailable
        }

        let callTimeout = Self.requestTimeout(until: requestDeadline)
        guard callTimeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }

        let response: Data
        do {
            response = try await provider.profile.connection.call(
                requestData,
                timeout: callTimeout
            )
        } catch {
            await invalidate(reason: "documentation_provider_call_failed")
            let retryTimeout = Self.requestTimeout(until: requestDeadline)
            guard retryTimeout?.nanoseconds != 0 else {
                throw error
            }
            guard let replacement = await providerIfAvailable(requestTimeout: retryTimeout) else {
                throw error
            }
            let retryResponse = try await replacement.profile.connection.call(
                requestData,
                timeout: retryTimeout
            )
            return DocumentationProviderCallResult(
                data: retryResponse,
                didInvalidateProvider: true
            )
        }
        guard DocumentationToolCatalog.responseIsDocumentationNotEnabled(response) else {
            return DocumentationProviderCallResult(data: response, didInvalidateProvider: false)
        }

        await invalidate(reason: "documentation_search_not_enabled")
        let retryTimeout = Self.requestTimeout(until: requestDeadline)
        guard retryTimeout?.nanoseconds != 0,
              let replacement = await providerIfAvailable(requestTimeout: retryTimeout) else {
            return DocumentationProviderCallResult(data: response, didInvalidateProvider: true)
        }
        do {
            let retryResponse = try await replacement.profile.connection.call(
                requestData,
                timeout: retryTimeout
            )
            if DocumentationToolCatalog.responseIsDocumentationNotEnabled(retryResponse) {
                await invalidate(reason: "documentation_search_retry_not_enabled")
            }
            return DocumentationProviderCallResult(
                data: retryResponse,
                didInvalidateProvider: true
            )
        } catch {
            return DocumentationProviderCallResult(data: response, didInvalidateProvider: true)
        }
    }

    package func invalidate(reason _: String) async {
        guard let provider = activeProvider else {
            return
        }
        activeProvider = nil
        await provider.profile.connection.stop()
    }

    package func shutdown() async {
        await invalidate(reason: "shutdown")
    }

    private func providerIfAvailable(requestTimeout: TimeAmount?) async -> ActiveProvider? {
        if let activeProvider {
            return activeProvider
        }
        guard let selected = await selectProvider(requestTimeout: requestTimeout) else {
            return nil
        }
        let provider = ActiveProvider(profile: selected)
        activeProvider = provider
        return provider
    }

    private func selectProvider(requestTimeout: TimeAmount?) async -> CandidateProfile? {
        let selectionDeadline = Self.requestDeadline(for: requestTimeout)
        var profiles: [CandidateProfile] = []
        for target in discovery.runningXcodeTargets() {
            guard !Task.isCancelled else {
                break
            }
            let candidateTimeout = Self.requestTimeout(until: selectionDeadline)
            if candidateTimeout?.nanoseconds == 0 {
                break
            }
            do {
                let profile = try await probe(target: target, requestTimeout: candidateTimeout)
                profiles.append(profile)
            } catch is CancellationError {
                break
            } catch {
                continue
            }
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
        return selected
    }

    private func probe(
        target: DocumentationProviderTarget,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        let probeDeadline = Self.requestDeadline(for: requestTimeout ?? .seconds(30))
        let session = try await sessionFactory.startSession(for: target)
        let connection = DocumentationProviderConnection(session: session)
        await connection.start()
        do {
            let initializeTimeout = Self.requestTimeout(until: probeDeadline)
            guard initializeTimeout?.nanoseconds != 0 else {
                throw TimeoutError()
            }
            let initialize = try await connection.call(
                try Self.makeInitializeRequestData(),
                timeout: initializeTimeout
            )
            let serverVersion = Self.serverVersion(fromInitializeResponse: initialize) ?? ""
            try Task.checkCancellation()
            try await connection.sendNotification([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ])
            let toolsListTimeout = Self.requestTimeout(until: probeDeadline)
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
            let documentationProbeTimeout = Self.requestTimeout(until: probeDeadline)
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

    private static func makeInitializeRequestData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "initialize",
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "XcodeMCPKitDocumentationProvider",
                        "version": "dev",
                    ],
                ],
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

    private static func requestDeadline(for requestTimeout: TimeAmount?) -> UInt64? {
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let remainingToMax = UInt64.max &- now
        let clamped = min(UInt64(requestTimeout.nanoseconds), remainingToMax)
        return now &+ clamped
    }

    private static func requestTimeout(until deadlineUptimeNs: UInt64?) -> TimeAmount? {
        guard let deadlineUptimeNs else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNs > now else {
            return .nanoseconds(0)
        }
        let remaining = deadlineUptimeNs - now
        return .nanoseconds(Int64(min(remaining, UInt64(Int64.max))))
    }
}
