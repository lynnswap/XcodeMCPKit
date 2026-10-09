import Foundation
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

final class NativeBrokerHost: Sendable {
    struct OwnedRuntime: Sendable {
        let runtime: any ProxyRuntimeServing
        let unsubscribe: @Sendable () -> Void
    }
    private struct State: Sendable {
        var activation: Task<OwnedRuntime, any Error>?
        var activationGeneration: UInt64 = 0
        var owned: OwnedRuntime?
        var stopped = false
    }
    let identifier: String
    let index: Int
    let installation: XcodeHostInstallation
    private let state = NIOLockedValueBox(State())
    private let create: @Sendable () throws -> any ProxyRuntimeServing
    private let receive: @Sendable (ProxyRuntimeEvent) -> Void

    init(identifier: String, index: Int, installation: XcodeHostInstallation,
         create: @escaping @Sendable () throws -> any ProxyRuntimeServing,
         receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void) {
        self.identifier = identifier
        self.index = index
        self.installation = installation
        self.create = create
        self.receive = receive
    }

    func activate() async throws -> any ProxyRuntimeServing {
        let attempt = state.withLockedValue { state -> (Task<OwnedRuntime, any Error>, UInt64) in
            if let task = state.activation { return (task, state.activationGeneration) }
            state.activationGeneration &+= 1
            let task = Task { [self] in
                try Task.checkCancellation()
                let runtime = try create()
                let unsubscribe = runtime.subscribeToEvents(receive)
                let owned = OwnedRuntime(runtime: runtime, unsubscribe: unsubscribe)
                guard !self.state.withLockedValue({ $0.stopped }), !Task.isCancelled else {
                    unsubscribe()
                    runtime.cancelForDeinit()
                    throw CancellationError()
                }
                runtime.start()
                let retained = self.state.withLockedValue { state in
                    guard !state.stopped else { return false }
                    state.owned = owned
                    return true
                }
                if !retained {
                    unsubscribe()
                    runtime.cancelForDeinit()
                    throw CancellationError()
                }
                return owned
            }
            state.activation = task
            return (task, state.activationGeneration)
        }
        do { return try await attempt.0.value.runtime }
        catch {
            state.withLockedValue { state in
                if state.activationGeneration == attempt.1 && state.owned == nil && !state.stopped {
                    state.activation = nil
                }
            }
            throw error
        }
    }

    var runtimeIfStarted: (any ProxyRuntimeServing)? { state.withLockedValue { $0.owned }?.runtime }

    var snapshot: ProxyRuntimeSnapshot? {
        state.withLockedValue { $0.owned }?.runtime.snapshot()
    }

    func cancel() {
        let pending = state.withLockedValue { state in
            state.stopped = true
            return (state.activation, state.owned)
        }
        pending.0?.cancel()
        pending.1?.runtime.cancelForDeinit()
    }

    func shutdown() async {
        let pending = state.withLockedValue { state in
            state.stopped = true
            return (state.activation, state.owned)
        }
        pending.0?.cancel()
        let owned: OwnedRuntime?
        if let value = pending.1 { owned = value }
        else if let task = pending.0 { owned = try? await task.value }
        else { owned = nil }
        if let owned {
            await owned.runtime.shutdown()
            owned.unsubscribe()
        }
    }
}

struct NativeBrokerChannel: Sendable {
    let hostIdentifier: String
    let sessionID: ProxySessionID
    let runtime: any ProxyRuntimeServing

    func execute(_ request: ProxyRuntimeRequest,
                 cancellation: NativeHostBrokerCancellation) async throws -> ProxyRuntimeReply {
        var request = request
        request.headerSessionExists = true
        return try await nativeHostBrokerReply(from: runtime, request: request,
                                               sessionID: sessionID, cancellation: cancellation)
    }

    func close() { runtime.removeSession(sessionID) }
}

final class NativeBrokerSession: Sendable {
    struct ChannelLoad: Sendable {
        let identifier: UUID
        let task: Task<NativeBrokerChannel, any Error>
    }
    struct State: Sendable {
        var selectedHost: String
        var protocolVersion: String?
        var activeRequests = 0
        var eventStreams = 0
        var activity = DispatchTime.now().uptimeNanoseconds
        var selectionRevision: UInt64 = 0
        var closed = false
        var operations: [UUID: NativeHostBrokerOperation] = [:]
        var channels: [String: ChannelLoad] = [:]
    }
    let identifier: ProxySessionID
    let state: NIOLockedValueBox<State>
    let initializeParameters: JSONValue

    init(identifier: ProxySessionID, defaultHost: String, initializeParameters: JSONValue) {
        self.identifier = identifier
        self.initializeParameters = initializeParameters
        state = NIOLockedValueBox(State(selectedHost: defaultHost))
    }

    func channel(
        for host: NativeBrokerHost,
        register: @escaping @Sendable (ProxySessionID) throws -> Void,
        unregister: @escaping @Sendable (ProxySessionID) -> Void
    ) async throws -> NativeBrokerChannel {
        let load = state.withLockedValue { state -> ChannelLoad in
            if let load = state.channels[host.identifier] { return load }
            let identifier = UUID()
            let task = Task { [self] in
                let runtime = try await host.activate()
                try Task.checkCancellation()
                let backendID = ProxySessionID(rawValue: UUID().uuidString)
                try register(backendID)
                let channel = NativeBrokerChannel(hostIdentifier: host.identifier,
                                                  sessionID: backendID, runtime: runtime)
                do {
                    let initialize = try ProxyRuntimeRequest(json: .object([
                        "jsonrpc": .string("2.0"), "id": .string("broker-initialize"),
                        "method": .string("initialize"), "params": initializeParameters,
                    ]), headerSessionExists: false, prefersEventStream: false)
                    let reply = try await nativeHostBrokerReply(
                        from: runtime, request: initialize, sessionID: backendID,
                        cancellation: NativeHostBrokerCancellation())
                    _ = try NativeHostBroker.result(in: reply)
                    let initialized = try ProxyRuntimeRequest(json: .object([
                        "jsonrpc": .string("2.0"),
                        "method": .string("notifications/initialized"),
                    ]), headerSessionExists: true, prefersEventStream: false)
                    _ = try await channel.execute(initialized, cancellation: NativeHostBrokerCancellation())
                    try Task.checkCancellation()
                    guard !self.state.withLockedValue({ $0.closed }) else { throw CancellationError() }
                    return channel
                } catch {
                    channel.close()
                    unregister(backendID)
                    throw error
                }
            }
            let load = ChannelLoad(identifier: identifier, task: task)
            state.channels[host.identifier] = load
            return load
        }
        do { return try await load.task.value }
        catch {
            state.withLockedValue { state in
                if state.channels[host.identifier]?.identifier == load.identifier {
                    state.channels.removeValue(forKey: host.identifier)
                }
            }
            throw error
        }
    }

    func close() -> Task<Void, Never> {
        let pending = state.withLockedValue { state in
            state.closed = true
            let operations = Array(state.operations.values)
            let channels = state.channels.values.map(\.task)
            state.operations.removeAll()
            state.channels.removeAll()
            return (operations, channels)
        }
        for operation in pending.0 { operation.cancel(reason: .channelInactive) }
        for channel in pending.1 { channel.cancel() }
        return Task {
            for task in pending.1 {
                if let channel = try? await task.value { channel.close() }
            }
        }
    }
}
