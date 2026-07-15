import Dispatch
import Foundation
import Testing
@testable import XcodeMCPProxyKit

struct StdioInputChannelTests {
    @Test func readsAcrossBoundedOperationsInOrderThenReportsEOF() async throws {
        try await expectRoundTrip(byteCount: 2 * 64 * 1024 + 257)
    }

    @Test func readsAnExactOperationBoundaryThenReportsEOF() async throws {
        try await expectRoundTrip(byteCount: 64 * 1024)
    }

    private func expectRoundTrip(byteCount: Int) async throws {
        let pipe = Pipe()
        let channel = StdioInputChannel(handle: pipe.fileHandleForReading)
        let expected = Data(
            (0..<byteCount).map { UInt8(truncatingIfNeeded: $0) }
        )
        let readTask = Task {
            var received = Data()
            while let chunk = try await channel.read() {
                received.append(chunk)
            }
            await channel.waitUntilStopped()
            return received
        }

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue(label: "StdioInputChannelTests.writer").async {
                    do {
                        try pipe.fileHandleForWriting.write(contentsOf: expected)
                        try pipe.fileHandleForWriting.close()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            channel.stop()
            _ = await readTask.result
            throw error
        }

        #expect(try await readTask.value == expected)
    }

    @Test func stopInterruptsActiveReadAndWaitsForDescriptorCleanup() async throws {
        let pipe = Pipe()
        let channel = StdioInputChannel(handle: pipe.fileHandleForReading)
        let firstRead = Task {
            try await channel.read()
        }
        let firstChunk = Data("a".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: firstChunk)
        #expect(try await firstRead.value == firstChunk)

        let pendingRead = Task {
            try await channel.read()
        }

        channel.stop()
        await #expect(throws: CancellationError.self) {
            try await pendingRead.value
        }
        await channel.waitUntilStopped()
        try pipe.fileHandleForWriting.close()
    }

    @Test func stopBeforeReadIsIdempotent() async throws {
        let pipe = Pipe()
        let channel = StdioInputChannel(handle: pipe.fileHandleForReading)

        channel.stop()
        channel.stop()
        await channel.waitUntilStopped()
        await #expect(throws: CancellationError.self) {
            try await channel.read()
        }
        try pipe.fileHandleForWriting.close()
    }
}
