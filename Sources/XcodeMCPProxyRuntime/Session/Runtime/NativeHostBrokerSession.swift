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
        var deactivation: Task<Void, Never>?
        var stopped = false
    }
    let identifier: String
    let index: Int
    let installation: XcodeHostInstallation
    let guiProcess: XcodeGUIProcess?
    let independent: Bool
    private let state = NIOLockedValueBox(State())
    private let create: @Sendable () throws -> any ProxyRuntimeServing
    private let receive: @Sendable (ProxyRuntimeEvent) -> Void

    init(identifier: String, index: Int, installation: XcodeHostInstallation, guiProcess: XcodeGUIProcess? = nil, independent: Bool = false,
         create: @escaping @Sendable () throws -> any ProxyRuntimeServing,
         receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void) {
        self.identifier = identifier
        self.index = index
        self.installation = installation
        self.guiProcess = guiProcess
        self.independent = independent
        self.create = create
        self.receive = receive
    }

    private enum Activation {
        case starting(Task<OwnedRuntime, any Error>, UInt64)
        case closing(Task<Void, Never>)
    }

    func activate() async throws -> any ProxyRuntimeServing {
        let attempt = try state.withLockedValue { state -> Activation in
            guard !state.stopped else { throw CancellationError() }
            if let closing = state.deactivation { return .closing(closing) }
            if let task = state.activation { return .starting(task, state.activationGeneration) }
            state.activationGeneration &+= 1
            let generation = state.activationGeneration
            let task = Task { [self] in
                try Task.checkCancellation()
                let runtime = try create()
                let unsubscribe = runtime.subscribeToEvents(receive)
                let owned = OwnedRuntime(runtime: runtime, unsubscribe: unsubscribe)
                guard self.state.withLockedValue({ !$0.stopped && $0.activationGeneration == generation }),
                      !Task.isCancelled else {
                    unsubscribe()
                    await runtime.shutdown()
                    throw CancellationError()
                }
                runtime.start()
                let retained = self.state.withLockedValue { state in
                    guard !state.stopped, state.activationGeneration == generation, !Task.isCancelled else { return false }
                    state.owned = owned
                    return true
                }
                if !retained {
                    unsubscribe()
                    await runtime.shutdown()
                    throw CancellationError()
                }
                return owned
            }
            state.activation = task
            return .starting(task, state.activationGeneration)
        }
        guard case .starting(let task, let generation) = attempt else {
            if case .closing(let closing) = attempt { await closing.value }
            return try await activate()
        }
        do { return try await task.value.runtime }
        catch {
            state.withLockedValue { state in
                if state.activationGeneration == generation && state.owned == nil && !state.stopped {
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

    func deactivate() -> Task<Void, Never>? {
        state.withLockedValue { state in
            guard !state.stopped, state.deactivation == nil,
                  state.activation != nil || state.owned != nil else { return nil }
            let activation = state.activation
            let owned = state.owned
            state.activation = nil
            state.owned = nil
            state.activationGeneration &+= 1
            activation?.cancel()
            let task = Task { [self] in
                let runtime: OwnedRuntime?
                if let owned { runtime = owned }
                else if let activation { runtime = try? await activation.value }
                else { runtime = nil }
                if let runtime {
                    await runtime.runtime.shutdown()
                    runtime.unsubscribe()
                }
                self.state.withLockedValue { $0.deactivation = nil }
            }
            state.deactivation = task
            return task
        }
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
            return (state.activation, state.owned, state.deactivation)
        }
        pending.0?.cancel()
        await pending.2?.value
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

    func source() throws -> ProxyRuntimeUpstreamSource {
        guard let source = runtime.snapshot().upstreamSource else {
            throw NativeHostBrokerError("The Xcode connection is unavailable; open or list workspaces again")
        }
        return source
    }

    func execute(_ request: ProxyRuntimeRequest, source: ProxyRuntimeUpstreamSource? = nil,
                 cancellation: NativeHostBrokerCancellation) async throws -> ProxyRuntimeReply {
        var request = request
        request.headerSessionExists = true
        request.expectedUpstreamSource = source
        return try await nativeHostBrokerReply(from: runtime, request: request,
                                               sessionID: sessionID, cancellation: cancellation)
    }

    func close() { runtime.removeSession(sessionID) }
}

final class NativeBrokerSession: Sendable {
    struct ChannelLoad: Sendable {
        let identifier: UUID
        let task: Task<NativeBrokerChannel, any Error>
        let isScopeOwned: Bool
        var closing: Task<Void, Never>?
    }
    struct State: Sendable {
        var protocolVersion: String?
        var activeRequests = 0
        var hostRequests: [String: Int] = [:]
        var eventStreams = 0
        var activity = DispatchTime.now().uptimeNanoseconds
        var closed = false
        var operations: [UUID: NativeHostBrokerOperation] = [:]
        var channels: [String: ChannelLoad] = [:]
        var workspaces: [String: NativeBrokerWorkspace] = [:]
        var deviceSessions: [String: NativeBrokerDeviceSession] = [:]
        var launchSessions: [String: NativeBrokerLaunchSession] = [:]

        func retainsHost(_ identifier: String) -> Bool {
            workspaces.values.contains { $0.hostIdentifier == identifier }
                || deviceSessions.values.contains { $0.hostIdentifier == identifier }
                || launchSessions.values.contains { $0.hostIdentifier == identifier }
        }
    }
    let identifier: ProxySessionID
    let state: NIOLockedValueBox<State>
    let initializeParameters: JSONValue

    init(identifier: ProxySessionID, initializeParameters: JSONValue) {
        self.identifier = identifier
        self.initializeParameters = initializeParameters
        state = NIOLockedValueBox(State())
    }

    func channel(
        for host: NativeBrokerHost,
        register: @escaping @Sendable (ProxySessionID) throws -> Void,
        unregister: @escaping @Sendable (ProxySessionID) -> Void
    ) async throws -> NativeBrokerChannel {
        let load = try state.withLockedValue { state -> ChannelLoad in
            guard !state.closed else { throw CancellationError() }
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
            let load = ChannelLoad(identifier: identifier, task: task,
                                   isScopeOwned: host.independent || host.guiProcess != nil)
            state.channels[host.identifier] = load
            return load
        }
        if let closing = load.closing {
            await closing.value
            return try await channel(for: host, register: register, unregister: unregister)
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

    func releaseHost(_ identifier: String) {
        state.withLockedValue { state in
            let remaining = (state.hostRequests[identifier] ?? 0) - 1
            if remaining == 0 { state.hostRequests.removeValue(forKey: identifier) }
            else { state.hostRequests[identifier] = remaining }
        }
    }

    func closeUnusedChannels(onClosed: @escaping @Sendable (ProxySessionID?) -> Void) {
        state.withLockedValue { state in
            guard !state.closed else { return }
            for (host, load) in state.channels
                where load.isScopeOwned && !state.retainsHost(host)
                    && state.hostRequests[host] == nil && load.closing == nil {
                let task = Task { [self] in
                    load.task.cancel()
                    let channel = try? await load.task.value
                    channel?.close()
                    self.state.withLockedValue { state in
                        if state.channels[host]?.identifier == load.identifier {
                            state.channels.removeValue(forKey: host)
                        }
                    }
                    onClosed(channel?.sessionID)
                }
                state.channels[host]?.closing = task
            }
        }
    }

    func close() -> Task<Void, Never> {
        let pending = state.withLockedValue { state in
            state.closed = true
            let operations = Array(state.operations.values)
            let channels = Array(state.channels.values)
            state.operations.removeAll()
            state.workspaces.removeAll()
            state.deviceSessions.removeAll()
            state.launchSessions.removeAll()
            return (operations, channels)
        }
        for operation in pending.0 { operation.cancel(reason: .channelInactive) }
        for channel in pending.1 { channel.task.cancel() }
        return Task { [self] in
            for operation in pending.0 { await operation.waitForWorkCompletion() }
            for load in pending.1 {
                if let closing = load.closing { await closing.value }
                else if let channel = try? await load.task.value { channel.close() }
            }
            state.withLockedValue { $0.channels.removeAll() }
        }
    }
}
