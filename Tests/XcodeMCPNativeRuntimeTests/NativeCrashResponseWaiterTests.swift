import Combine
import Foundation
import Synchronization
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeCrashResponseWaiterTests {
    @Test func aSynchronousResponseFinishesBeforeSubscriptionInstallation() throws {
        let waiter = NativeCrashResponseWaiter()

        let response = try waiter.wait(Just("response").setFailureType(to: Error.self)) { $0.uppercased() }

        #expect(response == "RESPONSE")
    }

    @Test func cancellationStopsAnInFlightHTTPRequestAndEndsTheWait() throws {
        let url = try #require(URL(string: "http://crash-waiter.invalid/\(UUID().uuidString)"))
        let observation = CrashHTTPObservation()
        CrashHTTPURLProtocol.observations.withLock { $0[url] = observation }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrashHTTPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let waiter = NativeCrashResponseWaiter()
        let outcome = Mutex<Result<String, any Error>?>(nil)
        let finished = DispatchGroup()
        finished.enter()
        defer {
            waiter.cancel()
            session.invalidateAndCancel()
            #expect(finished.wait(timeout: .now() + 5) == .success)
            CrashHTTPURLProtocol.observations.withLock { _ = $0.removeValue(forKey: url) }
        }
        DispatchQueue(label: "CrashResponseWaiterTests.worker").async {
            defer { finished.leave() }
            let result = Result {
                try waiter.wait(session.dataTaskPublisher(for: url)) { _ in "Unexpected response" }
            }
            outcome.withLock { $0 = result }
        }
        try #require(observation.started.wait(timeout: .now() + 5) == .success)

        waiter.cancel()

        try #require(finished.wait(timeout: .now() + 5) == .success)
        let result = try #require(outcome.withLock { $0 })
        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("A cancelled analytics request returned a response") }
        #expect(observation.stopped.wait(timeout: .now() + 5) == .success)
    }
}

private final class CrashHTTPObservation: Sendable {
    let started = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
}

private final class CrashHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    static let observations = Mutex<[URL: CrashHTTPObservation]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "crash-waiter.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let observation = Self.observations.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        observation.started.signal()
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        Self.observations.withLock { $0[url] }?.stopped.signal()
    }
}
