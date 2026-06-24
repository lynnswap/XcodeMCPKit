import Foundation
import Testing
import XcodeMCPTestSupport

@testable import ProxySession
@testable import ProxySessionUpstream

@Suite(.serialized, .enabled(if: ProcessTestEnvironment.isEnabled))
struct UpstreamProcessTests {
    @Test func upstreamSessionSendRemainsResponsiveUnderStdinBackpressure() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/cat",
            args: [],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 550_000
        )
        try await withUpstreamSession(config: config) { session in
            let payload = Data(repeating: 0x41, count: 500_000)
            let first = try await waitWithTimeout(
                "first send should complete before backpressure timeout",
                timeout: .seconds(5)
            ) {
                await session.send(payload)
            }
            switch first {
            case .accepted:
                break
            case .backpressure, .unavailable:
                Issue.record("first send should be accepted before queue reaches limit")
            }

            let second = try await waitWithTimeout(
                "second send should return promptly under backpressure",
                timeout: .seconds(5)
            ) {
                await session.send(payload)
            }
            switch second {
            case .accepted, .backpressure:
                break
            case .unavailable:
                Issue.record("queue-limit rejection should be backpressure, not unavailability")
            }
        }
    }

    @Test func upstreamSessionFlushesTrailingStderrLineWithoutNewline() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "printf 'fatal stderr' >&2"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamSession(config: config) { session in
            let stderr = try await waitWithTimeout(
                "stderr line should be flushed without newline",
                timeout: .seconds(2)
            ) {
                for await event in session.events {
                    switch event {
                    case .stderr(let message):
                        return message
                    case .message, .stdoutProtocolViolation, .stdoutBufferSize, .exit:
                        continue
                    }
                }
                return ""
            }

            #expect(stderr == "fatal stderr")
        }
    }

    @Test func upstreamSessionFlushesLargeStderrChunkWithoutWaitingForEOF() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "head -c 20000 /dev/zero | tr '\\0' 'x' >&2; sleep 1"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamSession(config: config) { session in
            let stderr = try await waitWithTimeout(
                "large stderr chunk should flush before EOF",
                timeout: .seconds(1)
            ) {
                for await event in session.events {
                    switch event {
                    case .stderr(let message):
                        return message
                    case .message, .stdoutProtocolViolation, .stdoutBufferSize, .exit:
                        continue
                    }
                }
                return ""
            }

            #expect(stderr.contains("[truncated]"))
        }
    }

    @Test func upstreamSessionEmitsBufferedStdoutResetWhenStopping() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/cat",
            args: [],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        let session = try await UpstreamProcess(config: config).startSession()
        defer {
            Task {
                await session.stop()
            }
        }

        let observedSizesRecorder = RecordedValues<Int>()
        let observedSizes = Task { () -> [Int] in
            var sizes: [Int] = []
            for await event in session.events {
                switch event {
                case .stdoutBufferSize(let size):
                    sizes.append(size)
                    await observedSizesRecorder.append(size)
                    if sizes.contains(where: { $0 > 0 }), sizes.contains(0) {
                        return sizes
                    }
                case .message, .stderr, .stdoutProtocolViolation, .exit:
                    continue
                }
            }
            return sizes
        }

        let sendResult = await session.send(Data("{".utf8))
        switch sendResult {
        case .accepted:
            break
        case .backpressure, .unavailable:
            Issue.record("send should not overload while checking buffered stdout reset")
        }

        _ = try await waitWithTimeout(
            "buffered stdout should become non-empty before stop",
            timeout: .seconds(2)
        ) {
            try await observedSizesRecorder.nextValue(matching: { $0 > 0 })
        }
        await session.stop()

        let sizes = try await waitWithTimeout(
            "buffered stdout should reset to zero after stop",
            timeout: .seconds(2)
        ) {
            await observedSizes.value
        }

        #expect(sizes.contains(where: { $0 > 0 }))
        #expect(sizes.contains(0))
    }

    @Test func upstreamSessionTreatsInvalidStdoutAsFatalProtocolViolation() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "printf 'Content-Length: abc\\r\\n\\r\\n{}'; sleep 5"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamSession(config: config) { session in
            let events = try await waitWithTimeout(
                "invalid stdout should emit a protocol violation",
                timeout: .seconds(3)
            ) {
                var sawViolation = false
                var bufferedSizes: [Int] = []

                for await event in session.events {
                    switch event {
                    case .stdoutProtocolViolation(let violation):
                        sawViolation = true
                        #expect(violation.reason == .invalidContentLengthHeader)
                    case .stdoutBufferSize(let size):
                        bufferedSizes.append(size)
                    case .message, .stderr, .exit:
                        continue
                    }

                    if sawViolation {
                        return bufferedSizes
                    }
                }

                return bufferedSizes
            }

            #expect(events.contains(where: { $0 > 0 }))
        }
    }

    @Test func upstreamSessionReturnsOverloadedWhenLaunchFails() async throws {
        let config = UpstreamProcess.Config(
            command: "/path/that/does/not/exist",
            args: [],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        let slot = ManagedUpstreamSlot(factory: UpstreamProcess(config: config))
        await slot.start()

        let first = await slot.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        let second = await slot.send(Data(#"{"jsonrpc":"2.0","id":2}"#.utf8))
        await slot.stop()

        #expect(first == .unavailable(.startFailed))
        #expect(second == .unavailable(.notStarted))
    }

    @Test func upstreamSessionRejectsWritesAfterExitEvent() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "printf '{\"jsonrpc\":\"2.0\",\"result\":{}}\\n'; exit 0"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamSession(config: config) { session in
            _ = try await waitWithTimeout(
                "session should emit exit before accepting more writes",
                timeout: .seconds(2)
            ) {
                for await event in session.events {
                    if case .exit = event {
                        return true
                    }
                }
                return false
            }

            let result = await session.send(Data(#"{"jsonrpc":"2.0","id":7}"#.utf8))
            #expect(result == .unavailable(.terminated))
        }
    }

    @Test func upstreamSessionReassemblesLargeJSONSplitAcrossOrderedChunks() async throws {
        let payload = try makeJSONRPCResponse(
            id: 41,
            text: String(repeating: "x", count: 128 * 1024)
        )
        let config = UpstreamProcess.Config(
            command: "/usr/bin/python3",
            args: makePythonChunkEmitterArgs(
                payloads: [payload],
                chunkSize: 4096,
                pauseSeconds: 0.001,
                keepAliveSeconds: 1
            ),
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamSession(config: config) { session in
            let message = try await waitWithTimeout(
                "large split JSON should be reconstructed as one message",
                timeout: .seconds(5)
            ) {
                for await event in session.events {
                    switch event {
                    case .message(let message):
                        return String(decoding: message, as: UTF8.self)
                    case .stdoutProtocolViolation(let violation):
                        return "VIOLATION:\(violation.reason.rawValue)"
                    case .stderr, .stdoutBufferSize, .exit:
                        continue
                    }
                }
                return ""
            }

            #expect(message == payload)
        }
    }

    @Test func upstreamSessionPreservesBackToBackLargeJSONMessageOrder() async throws {
        let payloads = try [
            makeJSONRPCResponse(id: 51, text: String(repeating: "a", count: 96 * 1024)),
            makeJSONRPCResponse(id: 52, text: String(repeating: "b", count: 96 * 1024)),
            makeJSONRPCResponse(id: 53, text: String(repeating: "c", count: 96 * 1024)),
        ]
        let config = UpstreamProcess.Config(
            command: "/usr/bin/python3",
            args: makePythonChunkEmitterArgs(
                payloads: payloads,
                chunkSize: 2048,
                pauseSeconds: 0.0005,
                keepAliveSeconds: 1
            ),
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamSession(config: config) { session in
            let messages = try await waitWithTimeout(
                "back-to-back large JSON payloads should preserve order",
                timeout: .seconds(5)
            ) {
                var messages: [String] = []
                for await event in session.events {
                    switch event {
                    case .message(let message):
                        messages.append(String(decoding: message, as: UTF8.self))
                        if messages.count == payloads.count {
                            return messages
                        }
                    case .stdoutProtocolViolation(let violation):
                        return ["VIOLATION:\(violation.reason.rawValue)"]
                    case .stderr, .stdoutBufferSize, .exit:
                        continue
                    }
                }
                return messages
            }

            #expect(messages == payloads)
        }
    }

    @Test func upstreamSessionDrainsFinalStdoutAfterImmediateExit() async throws {
        let payload = try makeJSONRPCResponse(
            id: 61,
            text: String(repeating: "z", count: 256 * 1024)
        )
        let config = UpstreamProcess.Config(
            command: "/usr/bin/python3",
            args: makePythonImmediateExitResponseArgs(id: 61, character: "z", repeatCount: 256 * 1024),
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )

        for _ in 0..<10 {
            try await withUpstreamSession(config: config) { session in
                let events = try await waitWithTimeout(
                    "final stdout should be drained before exit even when the process exits immediately",
                    timeout: .seconds(5)
                ) {
                    var observedEvents: [Upstream.Event] = []
                    for await event in session.events {
                        observedEvents.append(event)

                        let sawMessage = observedEvents.contains {
                            if case .message = $0 { return true }
                            return false
                        }
                        let sawExit = observedEvents.contains {
                            if case .exit = $0 { return true }
                            return false
                        }
                        if sawMessage && sawExit {
                            return observedEvents
                        }
                    }
                    return observedEvents
                }

                let message = events.compactMap { event -> String? in
                    guard case .message(let data) = event else {
                        return nil
                    }
                    return String(decoding: data, as: UTF8.self)
                }.first
                let messageIndex = events.firstIndex {
                    if case .message = $0 { return true }
                    return false
                }
                let exitIndex = events.firstIndex {
                    if case .exit = $0 { return true }
                    return false
                }

                if let message {
                    #expect(try canonicalJSONString(message) == canonicalJSONString(payload))
                } else {
                    Issue.record("expected a final stdout message before exit")
                }
                #expect(messageIndex != nil)
                #expect(exitIndex != nil)
                if let messageIndex, let exitIndex {
                    #expect(messageIndex < exitIndex)
                }
            }
        }
    }

    @Test func upstreamSessionEmitsExitWhenDescendantKeepsPipeOpen() async throws {
        let payload = try makeJSONRPCResponse(
            id: 62,
            text: String(repeating: "y", count: 8 * 1024)
        )
        let config = UpstreamProcess.Config(
            command: "/usr/bin/python3",
            args: makePythonForkingExitResponseArgs(
                id: 62,
                character: "y",
                repeatCount: 8 * 1024,
                childSleepSeconds: 2
            ),
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )

        try await withUpstreamSession(config: config) { session in
            let events = try await waitWithTimeout(
                "exit should not wait indefinitely for descendant-held pipe descriptors",
                timeout: .seconds(1)
            ) {
                var observedEvents: [Upstream.Event] = []
                for await event in session.events {
                    observedEvents.append(event)

                    let sawMessage = observedEvents.contains {
                        if case .message = $0 { return true }
                        return false
                    }
                    let sawExit = observedEvents.contains {
                        if case .exit = $0 { return true }
                        return false
                    }
                    if sawMessage && sawExit {
                        return observedEvents
                    }
                }
                return observedEvents
            }

            let message = events.compactMap { event -> String? in
                guard case .message(let data) = event else {
                    return nil
                }
                return String(decoding: data, as: UTF8.self)
            }.first
            let messageIndex = events.firstIndex {
                if case .message = $0 { return true }
                return false
            }
            let exitIndex = events.firstIndex {
                if case .exit = $0 { return true }
                return false
            }

            if let message {
                #expect(try canonicalJSONString(message) == canonicalJSONString(payload))
            } else {
                Issue.record("expected the parent process response before exit")
            }
            #expect(messageIndex != nil)
            #expect(exitIndex != nil)
            if let messageIndex, let exitIndex {
                #expect(messageIndex < exitIndex)
            }
        }
    }
}

private func withUpstreamSession<T: Sendable>(
    config: UpstreamProcess.Config,
    _ body: @escaping @Sendable (any UpstreamSession) async throws -> T
) async throws -> T {
    let session = try await UpstreamProcess(config: config).startSession()
    do {
        let result = try await body(session)
        await session.stop()
        return result
    } catch {
        await session.stop()
        throw error
    }
}

private func makeJSONRPCResponse(id: Int, text: String) throws -> String {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "text": text,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    return String(decoding: data, as: UTF8.self)
}

private func makePythonChunkEmitterArgs(
    payloads: [String],
    chunkSize: Int,
    pauseSeconds: Double,
    keepAliveSeconds: Double
) -> [String] {
    let script = """
    import sys
    import time

    chunk_size = int(sys.argv[1])
    pause = float(sys.argv[2])
    keep_alive = float(sys.argv[3])
    payloads = sys.argv[4:]

    for payload in payloads:
        for start in range(0, len(payload), chunk_size):
            sys.stdout.write(payload[start:start + chunk_size])
            sys.stdout.flush()
            time.sleep(pause)
        sys.stdout.write("\\n")
        sys.stdout.flush()

    time.sleep(keep_alive)
    """
    return ["-c", script, "\(chunkSize)", "\(pauseSeconds)", "\(keepAliveSeconds)"] + payloads
}

private func makePythonImmediateExitResponseArgs(
    id: Int,
    character: String,
    repeatCount: Int
) -> [String] {
    let script = """
    import json
    import sys

    payload = {
        "jsonrpc": "2.0",
        "id": int(sys.argv[1]),
        "result": {
            "text": sys.argv[2] * int(sys.argv[3]),
        },
    }
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\\n")
    sys.stdout.flush()
    """
    return ["-c", script, "\(id)", character, "\(repeatCount)"]
}

private func makePythonForkingExitResponseArgs(
    id: Int,
    character: String,
    repeatCount: Int,
    childSleepSeconds: Int
) -> [String] {
    let script = """
    import json
    import os
    import sys
    import time

    payload = {
        "jsonrpc": "2.0",
        "id": int(sys.argv[1]),
        "result": {
            "text": sys.argv[2] * int(sys.argv[3]),
        },
    }

    pid = os.fork()
    if pid == 0:
        time.sleep(float(sys.argv[4]))
        os._exit(0)

    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\\n")
    sys.stdout.flush()
    os._exit(0)
    """
    return ["-c", script, "\(id)", character, "\(repeatCount)", "\(childSleepSeconds)"]
}

private func canonicalJSONString(_ string: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
