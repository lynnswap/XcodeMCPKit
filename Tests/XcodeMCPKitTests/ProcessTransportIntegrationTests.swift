import Foundation
import Testing
@testable import XcodeMCPCore
@testable import XcodeMCPCoreTestSupport
@testable import XcodeMCPKit

@Suite(.serialized)
struct ProcessTransportIntegrationTests {
    @Test func stdoutEOFFailsUnboundedRequestsAfterDeliveringTheFinalResponse() async throws {
        let fakeDriver = FakeUpstreamProcessDriver(terminatesOnTerminate: false)
        let scheduler = ControlledTerminationDelayScheduler()
        let transport = try await UpstreamProcessXcodeMCPTransport.start(config: .init(
            command: "/fake/upstream",
            args: [],
            environment: [:],
            maxQueuedWriteBytes: 64 * 1024,
            terminationSignalGrace: .seconds(30),
            terminationDelayScheduler: scheduler,
            driverFactory: StaticUpstreamProcessDriverFactory(fakeDriver)
        ))
        defer {
            fakeDriver.emitTermination(status: 0)
            Task { await transport.close(headers: .init()) }
        }
        let initialize = Task {
            try await InitializedMCPClientSession.start(
                transport: transport,
                configuration: .init(
                    clientName: "EOFTest", clientVersion: "1", capabilities: [:],
                    requestTimeout: nil
                )
            )
        }
        defer { initialize.cancel() }
        let initializeMessage = try await fakeDriver.nextStdinMessage(method: "initialize")
        let initializeID = try #require(initializeMessage["id"])
        fakeDriver.emitStdout(try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": initializeID.foundationObject,
            "result": [
                "protocolVersion": "2025-06-18", "capabilities": [:],
                "serverInfo": ["name": "EOFTest", "version": "1"],
            ],
        ]))
        let session = try await initialize.value
        defer { Task { await session.close() } }
        let finalRequest = Task {
            try await session.request("final", deadline: nil, replayPolicy: .never)
        }
        let pendingRequest = Task {
            try await session.request("pending", deadline: nil, replayPolicy: .never)
        }
        defer {
            finalRequest.cancel()
            pendingRequest.cancel()
        }
        let finalMessage = try await fakeDriver.nextStdinMessage(method: "final")
        _ = try await fakeDriver.nextStdinMessage(method: "pending")
        let finalID = try #require(finalMessage["id"])
        fakeDriver.emitStdout(try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": finalID.foundationObject,
            "result": ["text": "last response"],
        ]))
        fakeDriver.finishStdout()

        let result = try await waitWithTimeout("final response before EOF") {
            try await finalRequest.value
        }
        #expect(result == .object(["text": .string("last response")]))
        let error = try await waitWithTimeout("pending request should fail before process exit") {
            switch await pendingRequest.result {
            case .success:
                Issue.record("unanswered request succeeded after stdout EOF")
                return nil as MCPBridgeRuntimeError?
            case .failure(let error):
                return error as? MCPBridgeRuntimeError
            }
        }
        guard case .transportUnavailable = error else {
            Issue.record("expected transport failure, got \(String(describing: error))")
            return
        }
        do {
            _ = try await waitWithTimeout("subsequent request should report unavailable") {
                try await session.request("afterEOF", deadline: nil)
            }
            Issue.record("request after EOF succeeded")
        } catch {
            guard case .transportUnavailable = error as? MCPBridgeRuntimeError else {
                Issue.record("expected unavailable transport after EOF, got \(error)")
                return
            }
        }
        #expect(fakeDriver.snapshot().forceTerminateCount == 0)
        #expect(fakeDriver.stdinWrites().filter {
            (try? JSONDecoder().decode(MCPJSONValue.self, from: $0))?["method"] == .string("pending")
        }.count == 1)

        let delay = try await scheduler.nextScheduledDelay()
        delay.fire()
        await session.close()
        #expect(fakeDriver.snapshot().terminateCount == 1)
        #expect(fakeDriver.snapshot().forceTerminateCount == 1)
    }

    @Test func processTransportDeinitSynchronouslySignalsOwnedProcess() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let config = UpstreamProcess.Config(
            command: "/fake/upstream",
            args: [],
            environment: [:],
            maxQueuedWriteBytes: 1024,
            driverFactory: StaticUpstreamProcessDriverFactory(fakeDriver)
        )
        var transport: UpstreamProcessXcodeMCPTransport? = try await .start(config: config)
        weak let weakTransport = transport

        transport = nil

        #expect(weakTransport == nil)
        let snapshot = fakeDriver.snapshot()
        #expect(snapshot.closeStdinCount == 1)
        #expect(snapshot.stopOutputCount == 1)
        #expect(snapshot.terminateCount == 1)
    }
}
