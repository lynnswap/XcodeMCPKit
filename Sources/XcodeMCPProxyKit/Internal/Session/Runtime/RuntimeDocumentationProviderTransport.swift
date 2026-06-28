import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPCore

final class RuntimeDocumentationProviderTransport: DocumentationProviderRouting {
    private struct State: Sendable {
        var initializeParamsByRouteID: [String: [String: JSONValue]] = [:]
        var fallbackRoutesByRouteID: [String: DocumentationProviderRoute] = [:]
    }

    private let runtimeBox: WeakRuntimeCoordinatorBox
    private let fallback: any DocumentationProviderRouting
    private let clock: ClockClient
    private let state = NIOLockedValueBox(State())

    init(
        runtimeBox: WeakRuntimeCoordinatorBox,
        fallback: any DocumentationProviderRouting = UnavailableRuntimeDocumentationProviderTransport(),
        clock: ClockClient = .liveValue
    ) {
        self.runtimeBox = runtimeBox
        self.fallback = fallback
        self.clock = clock
    }

    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout: TimeAmount?,
        initializeParams: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        if let runtime = runtimeBox.value,
            let route = runtime.documentationProviderRoute(for: target)
        {
            state.withLockedValue { state in
                state.initializeParamsByRouteID[route.id] = initializeParams
            }
            return route
        }
        return try await fallback.openRoute(
            for: target,
            requestTimeout: requestTimeout,
            initializeParams: initializeParams
        )
    }

    func toolsList(
        route: DocumentationProviderRoute,
        timeout: TimeAmount?
    ) async throws -> JSONValue {
        if let fallbackRoute = fallbackRouteIfActive(for: route) {
            return try await fallback.toolsList(route: fallbackRoute, timeout: timeout)
        }
        guard route.isRuntimeBorrowed else {
            return try await fallback.toolsList(route: route, timeout: timeout)
        }
        let deadline = Deadline.fromNow(timeout, clock: clock)
        do {
            guard let runtime = runtimeBox.value else { throw CancellationError() }
            return try await runtime.documentationProviderToolsList(
                route: route,
                requestTimeout: try remainingTimeoutOrThrow(until: deadline)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallbackRoute = try await openFallbackRoute(
                for: route,
                timeout: try remainingTimeoutOrThrow(until: deadline)
            )
            return try await fallback.toolsList(
                route: fallbackRoute,
                timeout: try remainingTimeoutOrThrow(until: deadline)
            )
        }
    }

    func callDocumentationSearch(
        route: DocumentationProviderRoute,
        requestData: Data,
        timeout: TimeAmount?
    ) async throws -> Data {
        if let fallbackRoute = fallbackRouteIfActive(for: route) {
            return try await fallback.callDocumentationSearch(
                route: fallbackRoute,
                requestData: requestData,
                timeout: timeout
            )
        }
        guard route.isRuntimeBorrowed else {
            return try await fallback.callDocumentationSearch(
                route: route,
                requestData: requestData,
                timeout: timeout
            )
        }
        let deadline = Deadline.fromNow(timeout, clock: clock)
        let response: Data
        do {
            guard let runtime = runtimeBox.value else { throw CancellationError() }
            response = try await runtime.documentationProviderCall(
                route: route,
                requestData: requestData,
                requestTimeout: try remainingTimeoutOrThrow(until: deadline)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallbackRoute = try await openFallbackRoute(
                for: route,
                timeout: try remainingTimeoutOrThrow(until: deadline)
            )
            return try await fallback.callDocumentationSearch(
                route: fallbackRoute,
                requestData: requestData,
                timeout: try remainingTimeoutOrThrow(until: deadline)
            )
        }
        guard Self.responseIsProxyUpstreamFailure(response) else {
            return response
        }
        let fallbackRoute = try await openFallbackRoute(
            for: route,
            timeout: try remainingTimeoutOrThrow(until: deadline)
        )
        return try await fallback.callDocumentationSearch(
            route: fallbackRoute,
            requestData: requestData,
            timeout: try remainingTimeoutOrThrow(until: deadline)
        )
    }

    func close(route: DocumentationProviderRoute) async {
        if !route.isRuntimeBorrowed {
            await fallback.close(route: route)
            return
        }
        let fallbackRoute = state.withLockedValue { state -> DocumentationProviderRoute? in
            state.initializeParamsByRouteID.removeValue(forKey: route.id)
            return state.fallbackRoutesByRouteID.removeValue(forKey: route.id)
        }
        if let fallbackRoute {
            await fallback.close(route: fallbackRoute)
        }
    }

    func shutdown() async {
        let fallbackRoutes = state.withLockedValue { state -> [DocumentationProviderRoute] in
            let routes = Array(state.fallbackRoutesByRouteID.values)
            state.initializeParamsByRouteID.removeAll()
            state.fallbackRoutesByRouteID.removeAll()
            return routes
        }
        for route in fallbackRoutes {
            await fallback.close(route: route)
        }
        await fallback.shutdown()
    }

    private func fallbackRouteIfActive(
        for route: DocumentationProviderRoute
    ) -> DocumentationProviderRoute? {
        guard route.isRuntimeBorrowed else {
            return nil
        }
        return state.withLockedValue { state in
            state.fallbackRoutesByRouteID[route.id]
        }
    }

    private func openFallbackRoute(
        for route: DocumentationProviderRoute,
        timeout: TimeAmount?
    ) async throws -> DocumentationProviderRoute {
        if let fallbackRoute = fallbackRouteIfActive(for: route) {
            return fallbackRoute
        }
        guard route.isRuntimeBorrowed else {
            return route
        }
        let initializeParams = state.withLockedValue { state in
            state.initializeParamsByRouteID[route.id]
        }
        guard let initializeParams else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let opened = try await fallback.openRoute(
            for: route.target,
            requestTimeout: timeout,
            initializeParams: initializeParams
        )
        var routeToClose: DocumentationProviderRoute?
        let selected = state.withLockedValue { state -> DocumentationProviderRoute? in
            guard state.initializeParamsByRouteID[route.id] != nil else {
                routeToClose = opened
                return nil
            }
            if let existing = state.fallbackRoutesByRouteID[route.id] {
                routeToClose = opened
                return existing
            }
            state.fallbackRoutesByRouteID[route.id] = opened
            routeToClose = nil
            return opened
        }
        if let routeToClose {
            await fallback.close(route: routeToClose)
        }
        guard let selected else {
            throw CancellationError()
        }
        return selected
    }

    private func remainingTimeoutOrThrow(until deadline: Deadline?) throws -> TimeAmount? {
        guard let deadline else {
            return nil
        }
        let remaining = deadline.remaining()
        guard remaining.nanoseconds > 0 else {
            throw TimeoutError()
        }
        return remaining
    }

    private static func responseIsProxyUpstreamFailure(_ data: Data) -> Bool {
        guard let error = JSONRPC.Wire.errorPayload(fromResponseData: data) else {
            return false
        }
        return (error.code == -32001 && error.message == "upstream unavailable")
            || (error.code == -32002 && error.message == "upstream overloaded")
    }
}

struct UnavailableRuntimeDocumentationProviderTransport: DocumentationProviderRouting {
    init() {}

    func openRoute(
        for _: XcodeProcessTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    func toolsList(
        route _: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    func callDocumentationSearch(
        route _: DocumentationProviderRoute,
        requestData _: Data,
        timeout _: TimeAmount?
    ) async throws -> Data {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }
}

extension RuntimeCoordinator {
    func documentationProviderRoute(
        for target: XcodeProcessTarget
    ) -> DocumentationProviderRoute? {
        guard let upstreamIndex = documentationUpstreamIndex(for: target) else {
            return nil
        }
        return DocumentationProviderRoute(
            id: "upstream-\(upstreamIndex)-pid-\(target.processID)",
            target: target,
            upstreamIndex: upstreamIndex
        )
    }

    func documentationProviderToolsList(
        route: DocumentationProviderRoute,
        requestTimeout: TimeAmount?
    ) async throws -> JSONValue {
        guard let upstreamIndex = route.upstreamIndex else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let rpcHandle = ControlPlane.RPCHandle()
        do {
            let response = try await performControlPlaneRPC(
                route: .pinnedUpstream(upstreamIndex),
                purpose: "documentation-tools",
                label: "tools/list:DocumentationProvider",
                requestObject: JSONRPC.Wire.requestObject(
                    id: "__documentation-tools-\(UUID().uuidString)",
                    method: "tools/list"
                ),
                requestTimeout: requestTimeout,
                rpcHandle: rpcHandle
            )
            return try extractJSONRPCResult(from: response.responseData)
        } catch let error as ControlPlane.RequestError {
            throw error.underlying
        }
    }

    func documentationProviderCall(
        route: DocumentationProviderRoute,
        requestData: Data,
        requestTimeout: TimeAmount?
    ) async throws -> Data {
        guard let upstreamIndex = route.upstreamIndex else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        guard
            var requestObject = try JSONSerialization.jsonObject(with: requestData, options: [])
                as? [String: Any],
            let originalID = JSONRPC.Message.Inspector.requestID(from: requestObject)
        else {
            throw ControlPlane.Error.invalidResponse("missing DocumentationSearch request id")
        }
        requestObject = JSONRPC.Wire.objectByReplacingID(
            in: requestObject,
            with: JSONRPC.ID(any: "__documentation-search-\(UUID().uuidString)")!
        )
        let rpcHandle = ControlPlane.RPCHandle()
        do {
            let response = try await performControlPlaneRPC(
                route: .pinnedUpstream(upstreamIndex),
                purpose: "documentation-search",
                label: "tools/call:DocumentationSearch",
                requestObject: requestObject,
                requestTimeout: requestTimeout,
                rpcHandle: rpcHandle,
                responseIDOverride: originalID,
                throwsOnRPCError: false
            )
            return response.responseData
        } catch let error as ControlPlane.RequestError {
            throw error.underlying
        }
    }
}
