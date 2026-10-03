import Foundation
import Testing
import XcodeMCPNativeRuntime

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NativeGUIConnectionTests {
    @Test func waitsForTheGUIConnectionBeforeSendingTheSessionContext() async throws {
        let transport = GUIConnectionTransportProbe()
        transport.connectsImmediately = false
        let connection = NativeGUIConnection(processIdentifier: 731, transport: transport)
        defer { try? connection.invalidate() }
        let initialization = Data([0x7B, 0x00, 0xFF, 0x7D])
        let startup = Task { @MainActor in try await connection.start(initializingWith: initialization) }
        defer { startup.cancel() }
        try await transport.nextActivation()
        #expect(!connection.isConnected)
        #expect(transport.oneWayMessages.isEmpty)
        transport.connect()
        try await startup.value
        #expect(connection.isConnected)
        #expect(transport.oneWayMessages == [initialization])
        #expect(transport.activationCount == 1)
    }

    @Test func requestsRepliesAndProgressRemainOpaqueAndOrdered() async throws {
        try await withGUIConnection { fixture in
            let input = Data([0x00, 0x01, 0x7B, 0xFF, 0x0A])
            let output = Data([0xFF, 0x00, 0x7D, 0x02, 0x0A])
            let request = Task { @MainActor in try await fixture.connection.request(input) }
            defer { request.cancel() }
            let sent = try await fixture.transport.nextRequest()
            #expect(sent.message == input)
            sent.respond(.success(output))
            #expect(try await request.value == output)

            let first = Data([0x00, 0xFF, 0x01])
            let second = Data("native-progress-値\n".utf8)
            fixture.transport.receive(first)
            fixture.transport.receive(second)
            var messages = fixture.connection.messages.makeAsyncIterator()
            #expect(await messages.next(isolation: MainActor.shared) == first)
            #expect(await messages.next(isolation: MainActor.shared) == second)
            #expect(fixture.transport.oneWayMessages == [fixture.initialization])
        }
    }

    @Test func repliesAreCorrelatedWhenConcurrentRequestsCompleteOutOfOrder() async throws {
        try await withGUIConnection { fixture in
            let first = Task { @MainActor in try await fixture.connection.request(Data("first request".utf8)) }
            defer { first.cancel() }
            let firstSent = try await fixture.transport.nextRequest()
            let second = Task { @MainActor in try await fixture.connection.request(Data("second request".utf8)) }
            defer { second.cancel() }
            let secondSent = try await fixture.transport.nextRequest()
            secondSent.respond(.success(Data("second response".utf8)))
            firstSent.respond(.success(Data("first response".utf8)))
            #expect(try await first.value == Data("first response".utf8))
            #expect(try await second.value == Data("second response".utf8))
        }
    }

    @Test func aRequestCancelledBeforeDeliverySendsNeitherActionNorCancellation() async throws {
        try await withGUIConnection { fixture in
            let request = Task { @MainActor in
                try await fixture.connection.request(Data("must not be delivered".utf8), cancellation: .nativeMessage(Data("must not cancel".utf8)))
            }
            request.cancel()
            await #expect(throws: CancellationError.self) { try await request.value }
            #expect(fixture.transport.requestMessages.isEmpty)
            #expect(fixture.transport.oneWayMessages == [fixture.initialization])
            #expect(fixture.connection.isConnected)
        }
    }

    @Test func actionCancellationWaitsForItsNativeReplyAndLeavesOtherRequestsRunning() async throws {
        try await withGUIConnection { fixture in
            let cancellation = Data([0x01, 0x00, 0xFF, 0x02])
            var completed = false
            let action = Task { @MainActor in
                defer { completed = true }
                return try await fixture.connection.request(Data("action".utf8), cancellation: .nativeMessage(cancellation))
            }
            defer { action.cancel() }
            let actionSent = try await fixture.transport.nextRequest()
            let other = Task { @MainActor in try await fixture.connection.request(Data("other action".utf8)) }
            defer { other.cancel() }
            let otherSent = try await fixture.transport.nextRequest()
            action.cancel()
            action.cancel()
            try await fixture.transport.nextOneWay(matching: cancellation)
            #expect(fixture.transport.oneWayMessages == [fixture.initialization, cancellation])
            #expect(!completed)
            otherSent.respond(.success(Data("unaffected".utf8)))
            #expect(try await other.value == Data("unaffected".utf8))
            #expect(!completed)
            actionSent.respond(.success(Data("native acknowledgement".utf8)))
            await #expect(throws: CancellationError.self) { try await action.value }
            #expect(completed)
            #expect(fixture.connection.isConnected)
            #expect(fixture.transport.invalidationCount == 0)
            #expect(fixture.transport.oneWayMessages == [fixture.initialization, cancellation])
        }
    }

    @Test func unsupportedActionCancellationRetainsTheNativeReplyAndReturnsItsActualResult() async throws {
        try await withGUIConnection { fixture in
            var completed = false
            let request = Task { @MainActor in
                defer { completed = true }
                return try await fixture.connection.request(Data("uncancellable action".utf8), cancellation: .waitForNativeCompletion)
            }
            let sent = try await fixture.transport.nextRequest()
            request.cancel()
            await Task.yield()
            #expect(!completed)
            #expect(fixture.transport.oneWayMessages == [fixture.initialization])
            sent.respond(.success(Data("native action completed".utf8)))
            #expect(try await request.value == Data("native action completed".utf8))
            #expect(completed)
            #expect(fixture.connection.isConnected)
        }
    }

    @Test func dispatchIsReportedOnlyAfterTheTransportAcceptsTheRequest() async throws {
        try await withGUIConnection { fixture in
            fixture.transport.sendError = .send
            var dispatched = false
            await #expect(throws: GUITransportTestError.send) {
                try await fixture.connection.request(Data("not sent".utf8), didSend: { dispatched = true })
            }
            #expect(!dispatched)
            fixture.transport.sendError = nil
            let request = Task { @MainActor in
                try await fixture.connection.request(Data("sent".utf8), didSend: { dispatched = true })
            }
            let sent = try await fixture.transport.nextRequest()
            #expect(dispatched)
            sent.respond(.success(Data("reply".utf8)))
            _ = try await request.value
        }
    }

    @Test func nonActionCancellationEndsOnlyTheLocalWaitAndIgnoresItsLateReply() async throws {
        try await withGUIConnection { fixture in
            let request = Task { @MainActor in try await fixture.connection.request(Data("list catalog".utf8)) }
            defer { request.cancel() }
            let sent = try await fixture.transport.nextRequest()
            request.cancel()
            await #expect(throws: CancellationError.self) { try await request.value }
            sent.respond(.success(Data("late catalog".utf8)))
            #expect(fixture.transport.oneWayMessages == [fixture.initialization])
            #expect(fixture.connection.isConnected)
            let next = Task { @MainActor in try await fixture.connection.request(Data("next request".utf8)) }
            defer { next.cancel() }
            let nextSent = try await fixture.transport.nextRequest()
            nextSent.respond(.success(Data("next reply".utf8)))
            #expect(try await next.value == Data("next reply".utf8))
        }
    }

    @Test func disconnectDuringActionCancellationResumesTheRetainedRequest() async throws {
        try await withGUIConnection { fixture in
            let cancellation = Data("cancel retained action".utf8)
            let request = Task { @MainActor in
                try await fixture.connection.request(Data("active mutation".utf8), cancellation: .nativeMessage(cancellation))
            }
            defer { request.cancel() }
            _ = try await fixture.transport.nextRequest()
            request.cancel()
            try await fixture.transport.nextOneWay(matching: cancellation)
            fixture.transport.disconnect()
            await #expect(throws: NativeGUIConnectionError.self) { try await request.value }
            #expect(!fixture.connection.isConnected)
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func invalidationResumesEveryPendingReplyAndFinishesTheMessageStream() async throws {
        try await withGUIConnection { fixture in
            let first = Task { @MainActor in try await fixture.connection.request(Data("first".utf8)) }
            defer { first.cancel() }
            let firstSent = try await fixture.transport.nextRequest()
            let second = Task { @MainActor in try await fixture.connection.request(Data("second".utf8)) }
            defer { second.cancel() }
            let secondSent = try await fixture.transport.nextRequest()
            try fixture.connection.invalidate()
            for pending in [first, second] {
                do {
                    _ = try await pending.value
                    Issue.record("A pending native GUI request succeeded after invalidation")
                } catch let error as NativeGUIConnectionError {
                    #expect(error.description.contains("731"))
                }
            }
            firstSent.respond(.success(Data("late first".utf8)))
            secondSent.respond(.success(Data("late second".utf8)))
            fixture.transport.receive(Data("late progress".utf8))
            var messages = fixture.connection.messages.makeAsyncIterator()
            #expect(await messages.next(isolation: MainActor.shared) == nil)
            try fixture.connection.invalidate()
            #expect(fixture.transport.invalidationCount == 1)
            #expect(!fixture.connection.isConnected)
            await #expect(throws: NativeGUIConnectionError.self) { try await fixture.connection.request(Data("after closure".utf8)) }
            #expect(fixture.transport.requestMessages.count == 2)
        }
    }

    @Test func peerAndCleanupFailuresArePreservedForEveryPendingRequest() async throws {
        try await withGUIConnection { fixture in
            let first = Task { @MainActor in try await fixture.connection.request(Data("first".utf8)) }
            defer { first.cancel() }
            _ = try await fixture.transport.nextRequest()
            let second = Task { @MainActor in try await fixture.connection.request(Data("second".utf8)) }
            defer { second.cancel() }
            _ = try await fixture.transport.nextRequest()
            fixture.transport.cleanupError = .cleanup
            fixture.transport.disconnect(with: GUITransportTestError.peer)
            for pending in [first, second] {
                do {
                    _ = try await pending.value
                    Issue.record("A disconnected native GUI request unexpectedly succeeded")
                } catch let error as NativeRuntimeError {
                    #expect(error.description.contains(GUITransportTestError.peer.description))
                    #expect(error.description.contains(GUITransportTestError.cleanup.description))
                }
            }
            let termination = try #require(fixture.connection.terminationError as? NativeRuntimeError)
            #expect(termination.description.contains(GUITransportTestError.peer.description))
            #expect(termination.description.contains(GUITransportTestError.cleanup.description))
            #expect(fixture.transport.invalidationCount == 1)
            fixture.transport.cleanupError = nil
        }
    }

    @Test func cancellationDeliveryFailureEndsAllPendingRequestsWithoutLosingItsCause() async throws {
        try await withGUIConnection { fixture in
            let request = Task { @MainActor in
                try await fixture.connection.request(Data("action".utf8), cancellation: .nativeMessage(Data("cancel".utf8)))
            }
            defer { request.cancel() }
            _ = try await fixture.transport.nextRequest()
            fixture.transport.oneWayError = .oneWay
            fixture.transport.cleanupError = .cleanup
            request.cancel()
            do {
                _ = try await request.value
                Issue.record("A request succeeded despite failed cancellation delivery")
            } catch let error as NativeRuntimeError {
                #expect(error.description.contains(GUITransportTestError.oneWay.description))
                #expect(error.description.contains(GUITransportTestError.cleanup.description))
            }
            #expect(!fixture.connection.isConnected)
            #expect(fixture.transport.invalidationCount == 1)
            fixture.transport.cleanupError = nil
        }
    }

    @Test func aNativeReplyErrorIsPreservedWithoutClosingTheConnection() async throws {
        try await withGUIConnection { fixture in
            let request = Task { @MainActor in try await fixture.connection.request(Data("request".utf8)) }
            defer { request.cancel() }
            let sent = try await fixture.transport.nextRequest()
            sent.respond(.failure(GUITransportTestError.peer))
            await #expect(throws: GUITransportTestError.peer) { try await request.value }
            #expect(fixture.connection.isConnected)
            #expect(fixture.connection.terminationError == nil)
        }
    }

    @Test func failedCancellationCleanupRemainsObservableAtShutdown() async throws {
        try await withGUIConnection { fixture in
            let action = Task { @MainActor in
                try await fixture.connection.request(Data("action".utf8), cancellation: .nativeMessage(Data("cancel".utf8)))
            }
            defer { action.cancel() }
            let actionSent = try await fixture.transport.nextRequest()
            let other = Task { @MainActor in try await fixture.connection.request(Data("other".utf8)) }
            defer { other.cancel() }
            let otherSent = try await fixture.transport.nextRequest()
            fixture.transport.oneWayError = .oneWay
            fixture.transport.cleanupError = .cleanup
            action.cancel()
            for pending in [action, other] {
                do {
                    _ = try await pending.value
                    Issue.record("A pending request succeeded after failed cancellation cleanup")
                } catch let error as NativeRuntimeError {
                    #expect(error.description.contains(GUITransportTestError.oneWay.description))
                    #expect(error.description.contains(GUITransportTestError.cleanup.description))
                }
            }
            fixture.transport.cleanupError = nil
            for _ in 0..<2 {
                #expect(throws: GUITransportTestError.cleanup) { try fixture.connection.invalidate() }
            }
            let termination = try #require(fixture.connection.terminationError as? NativeRuntimeError)
            #expect(termination.description.contains(GUITransportTestError.oneWay.description))
            #expect(termination.description.contains(GUITransportTestError.cleanup.description))
            #expect(fixture.transport.invalidationCount == 1)
            actionSent.respond(.success(Data("late action acknowledgement".utf8)))
            otherSent.respond(.success(Data("late other reply".utf8)))
            var messages = fixture.connection.messages.makeAsyncIterator()
            #expect(await messages.next(isolation: MainActor.shared) == nil)
        }
    }

    @Test func aTransportSendFailurePreservesItsErrorAndLeavesNoReplyWaiter() async throws {
        try await withGUIConnection { fixture in
            fixture.transport.sendError = .send
            await #expect(throws: GUITransportTestError.send) { try await fixture.connection.request(Data("failed send".utf8)) }
            fixture.transport.sendError = nil
            let next = Task { @MainActor in try await fixture.connection.request(Data("next".utf8)) }
            defer { next.cancel() }
            let nextSent = try await fixture.transport.nextRequest()
            nextSent.respond(.success(Data("next reply".utf8)))
            #expect(try await next.value == Data("next reply".utf8))
            #expect(fixture.connection.isConnected)
        }
    }

    @Test func cancellationWhileConnectingCleansUpWithoutSendingInitialization() async throws {
        let transport = GUIConnectionTransportProbe()
        transport.connectsImmediately = false
        let connection = NativeGUIConnection(processIdentifier: 731, transport: transport)
        defer { try? connection.invalidate() }
        let startup = Task { @MainActor in try await connection.start(initializingWith: Data("initialize".utf8)) }
        defer { startup.cancel() }
        try await transport.nextActivation()
        startup.cancel()
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(transport.oneWayMessages.isEmpty)
        #expect(transport.invalidationCount == 1)
        #expect(!connection.isConnected)
        transport.connect()
        #expect(!connection.isConnected)
        var messages = connection.messages.makeAsyncIterator()
        #expect(await messages.next(isolation: MainActor.shared) == nil)
    }

    @Test func aConnectionTimeoutClosesTheTransportAndRejectsLateActivation() async throws {
        let transport = GUIConnectionTransportProbe()
        transport.connectsImmediately = false
        let connection = NativeGUIConnection(processIdentifier: 731, transport: transport)
        defer { try? connection.invalidate() }
        do {
            try await connection.start(initializingWith: Data("initialize".utf8), timeout: .zero)
            Issue.record("A native GUI connection succeeded without activation")
        } catch let error as NativeRuntimeError {
            #expect(error.description.contains("Timed out connecting to Xcode process 731"))
        }
        #expect(transport.activationCount == 1)
        #expect(transport.invalidationCount == 1)
        #expect(transport.oneWayMessages.isEmpty)
        transport.connect()
        #expect(!connection.isConnected)
        var messages = connection.messages.makeAsyncIterator()
        #expect(await messages.next(isolation: MainActor.shared) == nil)
    }

    @Test func startupReportsBothActivationAndCleanupFailures() async throws {
        let transport = GUIConnectionTransportProbe()
        transport.activationError = .activation
        transport.cleanupError = .cleanup
        let connection = NativeGUIConnection(processIdentifier: 731, transport: transport)
        do {
            try await connection.start(initializingWith: Data("initialize".utf8))
            Issue.record("A connection succeeded despite activation failure")
        } catch let error as NativeRuntimeError {
            #expect(error.description.contains(GUITransportTestError.activation.description))
            #expect(error.description.contains(GUITransportTestError.cleanup.description))
        }
        #expect(transport.invalidationCount == 1)
        #expect(transport.oneWayMessages.isEmpty)
        #expect(!connection.isConnected)
    }

    @Test func failedSessionInitializationClosesTheConnection() async throws {
        let transport = GUIConnectionTransportProbe()
        transport.oneWayError = .oneWay
        let connection = NativeGUIConnection(processIdentifier: 731, transport: transport)
        await #expect(throws: GUITransportTestError.oneWay) {
            try await connection.start(initializingWith: Data("initialize".utf8))
        }
        #expect(transport.invalidationCount == 1)
        #expect(!connection.isConnected)
        #expect(connection.terminationError as? GUITransportTestError == .oneWay)
    }
}

@MainActor
private func withGUIConnection(_ body: @MainActor (GUIConnectionFixture) async throws -> Void) async throws {
    let fixture = GUIConnectionFixture()
    defer { try? fixture.connection.invalidate() }
    try await fixture.connection.start(initializingWith: fixture.initialization)
    try await body(fixture)
}

@MainActor
private final class GUIConnectionFixture {
    let transport = GUIConnectionTransportProbe()
    let connection: NativeGUIConnection
    let initialization = Data("opaque native session context".utf8)

    init() { connection = NativeGUIConnection(processIdentifier: 731, transport: transport) }
}

private enum GUITransportTestError: Error, Equatable, CustomStringConvertible {
    case activation, send, oneWay, cleanup, peer

    var description: String { "test-native-GUI-\(self.rawName)-failure" }

    private var rawName: String {
        switch self {
        case .activation: "activation"
        case .send: "send"
        case .oneWay: "one-way"
        case .cleanup: "cleanup"
        case .peer: "peer"
        }
    }
}

@MainActor
private final class GUITransportRequest {
    let message: Data
    private let reply: @MainActor @Sendable (Result<Data, any Error>) -> Void

    init(message: Data, reply: @escaping @MainActor @Sendable (Result<Data, any Error>) -> Void) {
        self.message = message
        self.reply = reply
    }

    func respond(_ result: Result<Data, any Error>) { reply(result) }
}

@MainActor
private final class GUIConnectionTransportProbe: NativeGUIConnectionTransport {
    var connectsImmediately = true
    var activationError: GUITransportTestError?
    var sendError: GUITransportTestError?
    var oneWayError: GUITransportTestError?
    var cleanupError: GUITransportTestError?
    private(set) var activationCount = 0
    private(set) var invalidationCount = 0
    private(set) var requestMessages: [Data] = []
    private(set) var oneWayMessages: [Data] = []
    private var connected: (@MainActor @Sendable () -> Void)?
    private var received: (@MainActor @Sendable (Data) -> Void)?
    private var invalidated: (@MainActor @Sendable ((any Error)?) -> Void)?
    private let activations = AsyncStream<Void>.makeStream()
    private let requests = AsyncStream<GUITransportRequest>.makeStream()
    private let oneWays = AsyncStream<Data>.makeStream()
    private var activationIterator: AsyncStream<Void>.Iterator
    private var requestIterator: AsyncStream<GUITransportRequest>.Iterator
    private var oneWayIterator: AsyncStream<Data>.Iterator

    init() {
        activationIterator = activations.stream.makeAsyncIterator()
        requestIterator = requests.stream.makeAsyncIterator()
        oneWayIterator = oneWays.stream.makeAsyncIterator()
    }

    func activate(connected: @escaping @MainActor @Sendable () -> Void,
                  receive: @escaping @MainActor @Sendable (Data) -> Void,
                  invalidated: @escaping @MainActor @Sendable ((any Error)?) -> Void) throws {
        activationCount += 1
        self.connected = connected
        self.received = receive
        self.invalidated = invalidated
        activations.continuation.yield(())
        if let activationError { throw activationError }
        if connectsImmediately { connected() }
    }

    func send(_ message: Data, reply: @escaping @MainActor @Sendable (Result<Data, any Error>) -> Void) throws {
        requestMessages.append(message)
        if let sendError { throw sendError }
        requests.continuation.yield(GUITransportRequest(message: message, reply: reply))
    }

    func sendOneWay(_ message: Data) throws {
        oneWayMessages.append(message)
        if let oneWayError { throw oneWayError }
        oneWays.continuation.yield(message)
    }

    func invalidate() throws {
        invalidationCount += 1
        if let cleanupError { throw cleanupError }
    }

    func connect() { connected?() }
    func receive(_ message: Data) { received?(message) }
    func disconnect(with error: (any Error)? = nil) { invalidated?(error) }

    func nextActivation() async throws {
        var iterator = activationIterator
        let activation: Void? = await iterator.next(isolation: MainActor.shared)
        activationIterator = iterator
        _ = try #require(activation)
    }

    func nextRequest() async throws -> GUITransportRequest {
        var iterator = requestIterator
        let request = await iterator.next(isolation: MainActor.shared)
        requestIterator = iterator
        return try #require(request)
    }

    func nextOneWay(matching expected: Data) async throws {
        var iterator = oneWayIterator
        while let message = await iterator.next(isolation: MainActor.shared) {
            oneWayIterator = iterator
            if message == expected { return }
        }
        Issue.record("Native GUI one-way message stream ended without the expected message")
    }
}
