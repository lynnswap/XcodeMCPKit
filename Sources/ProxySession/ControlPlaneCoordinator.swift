import Foundation
import Logging
import NIOConcurrencyHelpers
import ProxyMCP

package enum ControlPlaneRoute: Hashable, Sendable {
    case anyHealthy
    case pinnedUpstream(Int)

    package var debugLabel: String {
        switch self {
        case .anyHealthy:
            return "any_healthy"
        case .pinnedUpstream(let upstreamIndex):
            return "pinned_\(upstreamIndex)"
        }
    }
}

package struct CanonicalInitializeLoadResult: Sendable {
    package let result: JSONValue
    package let sourceUpstream: Int?
}

package struct CanonicalToolsCatalogLoadResult: Sendable {
    package let rawResult: JSONValue
    package let sourceUpstream: Int?
    package let durationMilliseconds: Int
}

package struct ControlPlaneWaiterCounts: Codable, Sendable {
    package let initialize: Int
    package let toolsCatalog: Int
    package let windows: Int
}

package struct ProxyControlPlaneDebugSnapshot: Codable, Sendable {
    package let phase: String
    package let canonicalInitializeSourceUpstream: Int?
    package let canonicalToolsSourceUpstream: Int?
    package let canonicalReady: Bool
    package let upstreamHandshakeStates: [String: String]
    package let waiterCounts: ControlPlaneWaiterCounts
    package let inFlightControlPlaneRequests: [String]
    package let lastIncompatibility: CanonicalBrokerIncompatibility?
}

package final class ControlPlaneDebugMirror: Sendable {
    private let state = NIOLockedValueBox<ProxyControlPlaneDebugSnapshot?>(nil)

    package init() {}

    package func snapshot() -> ProxyControlPlaneDebugSnapshot? {
        state.withLockedValue { $0 }
    }

    package func overwrite(_ snapshot: ProxyControlPlaneDebugSnapshot?) {
        state.withLockedValue { state in
            state = snapshot
        }
    }
}

package actor ControlPlaneCoordinator {
    package typealias InitializeLoader =
        @Sendable (_ deadlineUptimeNs: UInt64?) async throws -> CanonicalInitializeLoadResult
    package typealias ToolsCatalogLoader =
        @Sendable (_ deadlineUptimeNs: UInt64?) async throws -> CanonicalToolsCatalogLoadResult
    package typealias WindowsLoader =
        @Sendable (_ route: ControlPlaneRoute, _ deadlineUptimeNs: UInt64?) async throws -> JSONValue
    package typealias UpstreamHandshakeStatesProvider = @Sendable () -> [String: String]

    private enum Phase: String, Sendable {
        case idle
        case loadingInitialize = "loading_initialize"
        case loadingToolsCatalog = "loading_tools_catalog"
        case listingWindows = "listing_windows"
    }

    private struct WaiterState: Sendable {
        var initialize = 0
        var toolsCatalog = 0
        var windows = 0
    }

    private struct InitializeLoad: Sendable {
        let id: UUID
        let task: Task<CanonicalInitializeLoadResult, Error>
    }

    private struct ToolsCatalogLoad: Sendable {
        let id: UUID
        let task: Task<CanonicalToolsCatalogLoadResult, Error>
    }

    private struct WindowLoad: Sendable {
        let id: UUID
        let task: Task<JSONValue, Error>
    }

    private struct DeadlineExceeded: Error {}

    private let brokerState: CanonicalBrokerState
    private let debugMirror: ControlPlaneDebugMirror
    private let initializeLoader: InitializeLoader
    private let toolsCatalogLoader: ToolsCatalogLoader
    private let windowsLoader: WindowsLoader
    private let upstreamHandshakeStates: UpstreamHandshakeStatesProvider
    private let logger: Logger

    private var phase: Phase = .idle
    private var waiterState = WaiterState()
    private var initializeLoad: InitializeLoad?
    private var toolsCatalogLoad: ToolsCatalogLoad?
    private var windowLoads: [ControlPlaneRoute: WindowLoad] = [:]
    private var inFlightRequests = Set<String>()

    package init(
        brokerState: CanonicalBrokerState,
        debugMirror: ControlPlaneDebugMirror,
        initializeLoader: @escaping InitializeLoader,
        toolsCatalogLoader: @escaping ToolsCatalogLoader,
        windowsLoader: @escaping WindowsLoader,
        upstreamHandshakeStates: @escaping UpstreamHandshakeStatesProvider,
        logger: Logger
    ) {
        self.brokerState = brokerState
        self.debugMirror = debugMirror
        self.initializeLoader = initializeLoader
        self.toolsCatalogLoader = toolsCatalogLoader
        self.windowsLoader = windowsLoader
        self.upstreamHandshakeStates = upstreamHandshakeStates
        self.logger = logger
    }

    package func clientInitialize(deadlineUptimeNs: UInt64?) async throws -> JSONValue {
        waiterState.initialize += 1
        syncDebug()
        defer {
            waiterState.initialize -= 1
            syncDebug()
        }

        if let result = brokerState.initializeResult() {
            return result
        }

        let load = initializeLoad ?? startInitializeLoad()
        let loaded = try await waitForTask(load.task, deadlineUptimeNs: deadlineUptimeNs)
        return loaded.result
    }

    package func toolsCatalog(deadlineUptimeNs: UInt64?) async throws -> JSONValue {
        waiterState.toolsCatalog += 1
        syncDebug()
        defer {
            waiterState.toolsCatalog -= 1
            syncDebug()
        }

        if let rawResult = brokerState.toolsCatalogRaw() {
            return rawResult
        }

        let load = toolsCatalogLoad ?? startToolsCatalogLoad()
        let loaded = try await waitForTask(load.task, deadlineUptimeNs: deadlineUptimeNs)
        return loaded.rawResult
    }

    package func listWindows(
        route: ControlPlaneRoute,
        deadlineUptimeNs: UInt64?
    ) async throws -> JSONValue {
        waiterState.windows += 1
        syncDebug()
        defer {
            waiterState.windows -= 1
            syncDebug()
        }

        let load = windowLoads[route] ?? startWindowLoad(route: route)
        return try await waitForTask(load.task, deadlineUptimeNs: deadlineUptimeNs)
    }

    package func prewarmToolsCatalogIfNeeded() async {
        guard brokerState.toolsCatalogRaw() == nil, toolsCatalogLoad == nil else {
            syncDebug()
            return
        }
        let load = startToolsCatalogLoad()
        do {
            _ = try await load.task.value
        } catch {
            logger.debug("tools catalog prewarm failed", metadata: ["error": .string(String(describing: error))])
        }
    }

    package func seedToolsCatalog(
        _ rawResult: JSONValue,
        sourceUpstream: Int? = nil
    ) {
        let source = sourceUpstream ?? brokerState.toolsSourceUpstream() ?? 0
        brokerState.syncCanonicalToolsCatalog(rawResult, sourceUpstream: source)
        syncDebug()
    }

    package func invalidate(
        reason _: String,
        clearInitialize: Bool = false,
        clearToolsCatalog: Bool = true
    ) {
        initializeLoad?.task.cancel()
        toolsCatalogLoad?.task.cancel()
        for load in windowLoads.values {
            load.task.cancel()
        }
        initializeLoad = nil
        toolsCatalogLoad = nil
        windowLoads.removeAll()
        inFlightRequests.removeAll()
        phase = .idle
        if clearInitialize {
            brokerState.clearInitialize()
        }
        if clearToolsCatalog {
            brokerState.clearToolsCatalog()
        }
        syncDebug()
    }

    private func startInitializeLoad() -> InitializeLoad {
        phase = .loadingInitialize
        inFlightRequests.insert("initialize")
        let initializeLoader = self.initializeLoader
        let load = InitializeLoad(
            id: UUID(),
            task: Task.detached {
                return try await initializeLoader(nil)
            }
        )
        initializeLoad = load
        Task { [load] in
            let result: Result<CanonicalInitializeLoadResult, Error>
            do {
                result = .success(try await load.task.value)
            } catch {
                result = .failure(error)
            }
            self.completeInitializeLoad(id: load.id, result: result)
        }
        syncDebug()
        return load
    }

    private func startToolsCatalogLoad() -> ToolsCatalogLoad {
        phase = .loadingToolsCatalog
        inFlightRequests.insert("tools/list")
        let toolsCatalogLoader = self.toolsCatalogLoader
        let load = ToolsCatalogLoad(
            id: UUID(),
            task: Task.detached {
                return try await toolsCatalogLoader(nil)
            }
        )
        toolsCatalogLoad = load
        Task { [load] in
            let result: Result<CanonicalToolsCatalogLoadResult, Error>
            do {
                result = .success(try await load.task.value)
            } catch {
                result = .failure(error)
            }
            self.completeToolsCatalogLoad(id: load.id, result: result)
        }
        syncDebug()
        return load
    }

    private func startWindowLoad(route: ControlPlaneRoute) -> WindowLoad {
        phase = .listingWindows
        let requestKey = "tools/call:XcodeListWindows@\(route.debugLabel)"
        inFlightRequests.insert(requestKey)
        let windowsLoader = self.windowsLoader
        let load = WindowLoad(
            id: UUID(),
            task: Task.detached {
                return try await windowsLoader(route, nil)
            }
        )
        windowLoads[route] = load
        Task { [load, route] in
            let result: Result<JSONValue, Error>
            do {
                result = .success(try await load.task.value)
            } catch {
                result = .failure(error)
            }
            self.completeWindowLoad(id: load.id, route: route, result: result)
        }
        syncDebug()
        return load
    }

    private func finishRequest(_ request: String) {
        inFlightRequests.remove(request)
        syncDebug()
    }

    private func completeInitializeLoad(
        id: UUID,
        result: Result<CanonicalInitializeLoadResult, Error>
    ) {
        guard initializeLoad?.id == id else { return }
        initializeLoad = nil
        finishRequest("initialize")
        if case .success(let loaded) = result, let sourceUpstream = loaded.sourceUpstream {
            brokerState.syncCanonicalInitialize(
                loaded.result,
                sourceUpstream: sourceUpstream
            )
        }
        if toolsCatalogLoad == nil, windowLoads.isEmpty {
            phase = .idle
        }
        syncDebug()
    }

    private func completeToolsCatalogLoad(
        id: UUID,
        result: Result<CanonicalToolsCatalogLoadResult, Error>
    ) {
        guard toolsCatalogLoad?.id == id else { return }
        toolsCatalogLoad = nil
        finishRequest("tools/list")
        if case .success(let loaded) = result, let sourceUpstream = loaded.sourceUpstream {
            brokerState.syncCanonicalToolsCatalog(
                loaded.rawResult,
                sourceUpstream: sourceUpstream
            )
        }
        if initializeLoad == nil, windowLoads.isEmpty {
            phase = .idle
        }
        syncDebug()
    }

    private func completeWindowLoad(
        id: UUID,
        route: ControlPlaneRoute,
        result _: Result<JSONValue, Error>
    ) {
        guard windowLoads[route]?.id == id else { return }
        windowLoads.removeValue(forKey: route)
        finishRequest("tools/call:XcodeListWindows@\(route.debugLabel)")
        if initializeLoad == nil, toolsCatalogLoad == nil, windowLoads.isEmpty {
            phase = .idle
        }
        syncDebug()
    }

    private func waitForTask<Output: Sendable>(
        _ task: Task<Output, Error>,
        deadlineUptimeNs: UInt64?
    ) async throws -> Output {
        guard let deadlineUptimeNs else {
            return try await task.value
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadlineUptimeNs {
            throw DeadlineExceeded()
        }

        let timeoutTask = Task {
            let remaining = deadlineUptimeNs &- now
            try? await Task.sleep(nanoseconds: remaining)
        }
        defer { timeoutTask.cancel() }

        return try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask {
                try await task.value
            }
            group.addTask {
                _ = await timeoutTask.result
                throw DeadlineExceeded()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func syncDebug() {
        let brokerSnapshot = brokerState.snapshot()
        let snapshot = ProxyControlPlaneDebugSnapshot(
            phase: phase.rawValue,
            canonicalInitializeSourceUpstream: brokerSnapshot.initializeSourceUpstream,
            canonicalToolsSourceUpstream: brokerSnapshot.toolsSourceUpstream,
            canonicalReady: brokerSnapshot.canonicalReady,
            upstreamHandshakeStates: upstreamHandshakeStates(),
            waiterCounts: ControlPlaneWaiterCounts(
                initialize: waiterState.initialize,
                toolsCatalog: waiterState.toolsCatalog,
                windows: waiterState.windows
            ),
            inFlightControlPlaneRequests: inFlightRequests.sorted(),
            lastIncompatibility: brokerSnapshot.lastIncompatibility
        )
        debugMirror.overwrite(snapshot)
    }
}
