import Foundation
import Testing
@testable import XcodeMCPCore
@testable import XcodeMCPCoreTestSupport

@Suite(.serialized)
struct CoreHTTPClientLifecycleTests {
    @Test func streamableHTTPInjectedClientDeinitCancelsEventStreamTask() async throws {
        let stub = CoreHTTPStub(endsGET: true)
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.remove() }
        let sleeps = DeterministicRecorder<Duration>()
        let cancelled = DeterministicRecorder<Void>()
        var client: StreamableHTTPMCPClient? = StreamableHTTPMCPClient(
            endpoint: stub.endpoint, urlSession: session, urlSessionOwnership: .injected,
            eventStreamReconnectSleep: { duration in
                sleeps.record(duration)
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch { cancelled.record(()); throw error }
            }
        )
        weak var weakClient = client
        await client?.startEventStream(headers: stub.headers)
        _ = try await stub.requests.nextValue(matching: { $0 == "GET" })
        _ = try await sleeps.nextValue(at: 0)
        client = nil
        #expect(weakClient == nil)
        _ = try await cancelled.nextValue(at: 0)
    }

    @Test func streamableHTTPOwnedClientDeinitInvalidatesOutstandingRequests() async throws {
        let stub = CoreHTTPStub()
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.remove() }
        var client: StreamableHTTPMCPClient? = StreamableHTTPMCPClient(
            endpoint: stub.endpoint, urlSession: session, urlSessionOwnership: .owned
        )
        weak var weakClient = client
        await client?.startEventStream(headers: stub.headers)
        _ = try await stub.requests.nextValue(matching: { $0 == "GET" })
        var request = URLRequest(url: stub.endpoint)
        request.httpMethod = "DELETE"
        let deletion = Task { _ = try? await session.data(for: request) }
        _ = try await stub.requests.nextValue(matching: { $0 == "DELETE" })
        client = nil
        #expect(weakClient == nil)
        _ = try await stub.cancelled.nextValue(matching: { $0 == "GET" })
        _ = try await stub.cancelled.nextValue(matching: { $0 == "DELETE" })
        await deletion.value
    }

    @Test func streamableHTTPConcurrentCloseDeletesAndInvalidatesOnce() async throws {
        let stub = CoreHTTPStub()
        let invalidations = CoreSessionInvalidations()
        let session = stub.makeSession(delegate: invalidations)
        defer { session.invalidateAndCancel(); stub.remove() }
        let client = StreamableHTTPMCPClient(endpoint: stub.endpoint, urlSession: session, urlSessionOwnership: .owned)
        await client.startEventStream(headers: stub.headers)
        _ = try await stub.requests.nextValue(matching: { $0 == "GET" })
        let started = DeterministicRecorder<Void>()
        let completed = DeterministicRecorder<Void>()
        let first = Task {
            started.record(())
            await client.close(headers: stub.headers, deleteTimeout: .seconds(2))
            completed.record(())
        }
        let second = Task {
            started.record(())
            await client.close(headers: stub.headers, deleteTimeout: .seconds(2))
            completed.record(())
        }
        _ = try await started.nextValue(at: 1)
        _ = try await stub.requests.nextValue(matching: { $0 == "DELETE" })
        for _ in 0..<100 { await Task.yield() }
        #expect(stub.requests.snapshot().filter { $0 == "DELETE" }.count == 1)
        #expect(completed.snapshot().isEmpty)
        stub.finishDelete()
        try await waitWithTimeout("close callers did not finish") { await first.value; await second.value }
        _ = try await invalidations.calls.nextValue(at: 0)
        #expect(completed.snapshot().count == 2)
        #expect(invalidations.calls.snapshot().count == 1)
        #expect(stub.requests.snapshot().filter { $0 == "DELETE" }.count == 1)
    }

    @Test func streamableHTTPCloseWaitsForReservedEventTaskInstallationAndTerminal() async throws {
        let state = StreamableHTTPMCPConnectionState()
        #expect(await state.reserveEventStreamStart())
        let gate = CoreLateTaskGate()
        let lateTask = Task { await gate.wait() }
        let returns = DeterministicRecorder<Void>()
        let terminals = DeterministicRecorder<Void>()
        let closing = Task {
            let task = await state.close()
            returns.record(())
            await task?.value
            terminals.record(())
        }
        while true {
            do { try await state.ensureOpen(); await Task.yield() }
            catch { break }
        }
        #expect(returns.snapshot().isEmpty)
        await state.installEventStreamTask(lateTask)
        _ = try await returns.nextValue(at: 0)
        #expect(terminals.snapshot().isEmpty)
        await gate.open()
        await closing.value
        #expect(terminals.snapshot().count == 1)
    }
}

private final class CoreHTTPStub: @unchecked Sendable {
    let endpoint = URL(string: "http://core-lifecycle.invalid/\(UUID().uuidString)")!
    let headers = MCPConnectionHeaders(sessionID: "session-core", protocolVersion: "2025-06-18")
    let requests = DeterministicRecorder<String>()
    let cancelled = DeterministicRecorder<String>()
    private let endsGET: Bool
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: CoreHTTPURLProtocol] = [:]

    init(endsGET: Bool = false) {
        self.endsGET = endsGET
        CoreHTTPRegistry.shared.insert(self)
    }

    func makeSession(delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoreHTTPURLProtocol.self]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func start(_ connection: CoreHTTPURLProtocol) {
        let method = connection.request.httpMethod ?? "GET"
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        if method == "GET" {
            let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            connection.client?.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
            connection.client?.urlProtocol(connection, didLoad: Data(": connected\n\n".utf8))
            if endsGET {
                _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
                connection.client?.urlProtocolDidFinishLoading(connection)
            }
        } else if method == "DELETE" {
            let response = HTTPURLResponse(url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!
            connection.client?.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        requests.record(method)
    }

    func stop(_ connection: CoreHTTPURLProtocol) {
        let removed = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
        if removed != nil { cancelled.record(connection.request.httpMethod ?? "GET") }
    }

    func finishDelete() {
        let pending = lock.withLock {
            let values = connections.values.filter { $0.request.httpMethod == "DELETE" }
            for value in values { connections.removeValue(forKey: ObjectIdentifier(value)) }
            return values
        }
        for connection in pending {
            connection.client?.urlProtocolDidFinishLoading(connection)
        }
    }

    func remove() {
        CoreHTTPRegistry.shared.remove(endpoint)
        let pending = lock.withLock { let values = Array(connections.values); connections.removeAll(); return values }
        for connection in pending { connection.client?.urlProtocol(connection, didFailWithError: URLError(.cancelled)) }
    }
}

private final class CoreHTTPRegistry: @unchecked Sendable {
    static let shared = CoreHTTPRegistry()
    private let lock = NSLock()
    private var stubs: [URL: CoreHTTPStub] = [:]
    func insert(_ stub: CoreHTTPStub) { lock.withLock { stubs[stub.endpoint] = stub } }
    func lookup(_ url: URL) -> CoreHTTPStub? { lock.withLock { stubs[url] } }
    func remove(_ url: URL) { _ = lock.withLock { stubs.removeValue(forKey: url) } }
}

private final class CoreHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "core-lifecycle.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = CoreHTTPRegistry.shared.lookup(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        stub.start(self)
    }
    override func stopLoading() { if let url = request.url { CoreHTTPRegistry.shared.lookup(url)?.stop(self) } }
}

private final class CoreSessionInvalidations: NSObject, URLSessionDelegate, @unchecked Sendable {
    let calls = DeterministicRecorder<Void>()
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) { calls.record(()) }
}

// Completion of this task remains independently controlled after cancellation.
private actor CoreLateTaskGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
