import Foundation
import NIO
import NIOConcurrencyHelpers
import ProxySessionControlPlane
import ProxyCore
import ProxyMCP

package final class RuntimeDocumentationProviderTransport: DocumentationProviderRouting {
    private struct State: Sendable {
        var initializeParamsByRouteID: [String: [String: JSONValue]] = [:]
        var fallbackRoutesByRouteID: [String: DocumentationProviderRoute] = [:]
    }

    private let runtimeBox: WeakRuntimeCoordinatorBox
    private let fallback: any DocumentationProviderRouting
    private let clock: ClockClient
    private let state = NIOLockedValueBox(State())

    package init(
        runtimeBox: WeakRuntimeCoordinatorBox,
        fallback: any DocumentationProviderRouting = UnavailableRuntimeDocumentationProviderTransport(),
        clock: ClockClient = .liveValue
    ) {
        self.runtimeBox = runtimeBox
        self.fallback = fallback
        self.clock = clock
    }

    package func openRoute(
        for target: DocumentationProviderTarget,
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

    package func toolsList(
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
        guard let runtime = runtimeBox.value else { throw CancellationError() }
        return try await runtime.documentationProviderToolsList(
            route: route,
            requestTimeout: try remainingTimeoutOrThrow(until: deadline)
        )
    }

    package func callDocumentationSearch(
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

    package func close(route: DocumentationProviderRoute) async {
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

    package func shutdown() async {
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
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [])
            as? [String: Any],
            let error = object["error"] as? [String: Any],
            let code = (error["code"] as? NSNumber)?.intValue,
            let message = error["message"] as? String
        else {
            return false
        }
        return (code == -32001 && message == "upstream unavailable")
            || (code == -32002 && message == "upstream overloaded")
    }
}

package struct UnavailableRuntimeDocumentationProviderTransport: DocumentationProviderRouting {
    package init() {}

    package func openRoute(
        for _: DocumentationProviderTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    package func toolsList(
        route _: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    package func callDocumentationSearch(
        route _: DocumentationProviderRoute,
        requestData _: Data,
        timeout _: TimeAmount?
    ) async throws -> Data {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }
}

extension RuntimeCoordinator {
    package func documentationProviderRoute(
        for target: DocumentationProviderTarget
    ) -> DocumentationProviderRoute? {
        documentationProviderRoutes.first { route in
            route.target.processID == target.processID
        }
    }

    package func documentationProviderToolsList(
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
                requestObject: [
                    "jsonrpc": "2.0",
                    "id": "__documentation-tools-\(UUID().uuidString)",
                    "method": "tools/list",
                ],
                requestTimeout: requestTimeout,
                rpcHandle: rpcHandle
            )
            return try extractJSONRPCResult(from: response.responseData)
        } catch let error as ControlPlane.RequestError {
            throw error.underlying
        }
    }

    package func documentationProviderCall(
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
        requestObject["id"] = "__documentation-search-\(UUID().uuidString)"
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
