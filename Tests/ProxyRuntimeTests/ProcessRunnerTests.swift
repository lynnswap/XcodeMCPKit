import Foundation
import Testing
import XcodeMCPTestSupport

@testable import ProxySession

@Suite(.serialized)
struct ProcessRunnerTests {
    @Test func dispatchGroupLeaveGuardLeavesOnlyOnce() {
        let group = DispatchGroup()
        let guarder = DispatchGroupLeaveGuard(group: group)

        guarder.leaveIfNeeded()
        guarder.leaveIfNeeded()

        #expect(group.wait(timeout: .now()) == .success)
    }

    @Test func processRunnerDrainsLargeStdoutWithoutHanging() async throws {
        let runner = ProcessRunner()
        let output = try await waitWithTimeout(
            "ProcessRunner should finish draining large stdout",
            timeout: .seconds(5)
        ) {
            try await runner.run(
                ProcessRequest(
                    label: "large-stdout",
                    executablePath: "/bin/sh",
                    arguments: ["-c", "yes x | head -c 200000"],
                    input: nil
                )
            )
        }

        #expect(output.terminationStatus == 0)
        #expect(output.stdout.utf8.count == 200000)
    }

    @Test func processRunnerPreservesLargeChunkedStdoutOrder() async throws {
        let runner = ProcessRunner()
        let segments = (0..<64).map { index in
            let prefix = "[\(String(index).leftPadding(toLength: 3, withPad: "0"))]"
            let scalar = UnicodeScalar(65 + (index % 26))!
            return prefix + String(repeating: Character(scalar), count: 2048)
        }
        let expected = segments.joined()
        let output = try await waitWithTimeout(
            "ProcessRunner should preserve large chunk ordering",
            timeout: .seconds(5)
        ) {
            try await runner.run(
                ProcessRequest(
                    label: "ordered-large-stdout",
                    executablePath: "/usr/bin/python3",
                    arguments: makePythonSegmentEmitterArgs(segments: segments, pauseSeconds: 0.0005),
                    input: nil
                )
            )
        }

        #expect(output.terminationStatus == 0)
        #expect(output.stdout == expected)
    }
}

private extension String {
    func leftPadding(toLength length: Int, withPad pad: String) -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

private func makePythonSegmentEmitterArgs(
    segments: [String],
    pauseSeconds: Double
) -> [String] {
    let script = """
    import sys
    import time

    pause = float(sys.argv[1])
    for segment in sys.argv[2:]:
        sys.stdout.write(segment)
        sys.stdout.flush()
        time.sleep(pause)
    """
    return ["-c", script, "\(pauseSeconds)"] + segments
}
