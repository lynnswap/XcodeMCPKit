import Darwin
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime
import XcodeMCPWire

@Suite
struct NativeApplicationLaunchTests {
    @Test func onlyAnOptedInTestAgentInTheSelectedSimulatorCanResume() {
        let device = UUID()
        var process = NativeApplicationLaunch.ProcessSnapshot(
            executable: "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest",
            startedSeconds: 10, startedMicroseconds: 0, stopped: true, traced: false,
            workingDirectory: "/a/device/set/\(device)/data")
        #expect(!process.canResume(in: device))
        #expect(process.canResume(in: device, allowTestAgent: true))
        #expect(!process.canResume(in: UUID(), allowTestAgent: true))
        process.traced = true
        #expect(!process.canResume(in: device, allowTestAgent: true))
        process.traced = false
        process.stopped = false
        #expect(!process.canResume(in: device, allowTestAgent: true))
        process.stopped = true
        process.workingDirectory = nil
        #expect(!process.canResume(in: device, allowTestAgent: true))
        process.workingDirectory = "/a/device/set/\(device)/data/Library"
        #expect(!process.canResume(in: device, allowTestAgent: true))
        process.workingDirectory = "/a/device/set/\(device)/data"
        process.executable = "/tmp/xctest"
        #expect(!process.canResume(in: device, allowTestAgent: true))
    }

    @Test(arguments: [false, true], [false, true])
    func onlyAnActiveTestRequestResumesItsStoppedHost(cancelled: Bool, hostless: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let device = UUID()
        let data = root.appendingPathComponent("\(device)/data")
        let directory = hostless
            ? root.appendingPathComponent("Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents")
            : data.appendingPathComponent("Containers/Bundle/Application/\(UUID())/Fixture.app")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(hostless ? "xctest" : "Fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = data
        process.arguments = ["60"]
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        #expect(kill(process.processIdentifier, SIGSTOP) == 0)
        let launch = NativeApplicationLaunch(processIdentifier: process.processIdentifier, simulatorIdentifier: device)
        for _ in 0..<100 where launch.captureSuspendedProcess(allowTestAgent: hostless) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(launch.captureSuspendedProcess(allowTestAgent: hostless))
        let scope = NativeExecutionOperations.Scope()
        try scope.resumeTestHostIfNeeded(launch)
        #expect(launch.captureSuspendedProcess(allowTestAgent: hostless) != nil)
        scope.prepareTestHosts()
        if cancelled { scope.cancel() }
        try scope.resumeTestHostIfNeeded(launch)
        if !cancelled {
            for _ in 0..<100 where launch.captureSuspendedProcess(allowTestAgent: hostless) != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect((launch.captureSuspendedProcess(allowTestAgent: hostless) != nil) == cancelled)
    }

    @Test(arguments: [nil, "Xcode.DebuggerFoundation.Debugger.LLDB"] as [String?], [false, true])
    func cancellationReapsOnlyTheOwnedSuspendedProcess(debuggerIdentifier: String?, hostless: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let device = UUID()
        let data = root.appendingPathComponent("\(device)/data")
        let directory = hostless
            ? root.appendingPathComponent("Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents")
            : data.appendingPathComponent("Containers/Bundle/Application/\(UUID())/Fixture.app")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(hostless ? "xctest" : "Fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = data
        process.arguments = ["60"]
        let terminated = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            terminated.continuation.yield(process.terminationStatus)
            terminated.continuation.finish()
        }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        try process.run()
        #expect(kill(process.processIdentifier, SIGSTOP) == 0)
        let launch = NativeApplicationLaunch(processIdentifier: process.processIdentifier,
            debuggerIdentifier: debuggerIdentifier, simulatorIdentifier: device)
        for _ in 0..<100 where launch.captureSuspendedProcess(allowTestAgent: hostless) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let captured = try #require(launch.captureSuspendedProcess(allowTestAgent: hostless))
        if debuggerIdentifier != nil {
            try launch.resumeIfStopped(allowTestAgent: hostless)
            #expect(launch.captureSuspendedProcess(allowTestAgent: hostless) != nil)
        }
        var physical = launch
        physical.simulatorIdentifier = nil
        #expect(physical.captureSuspendedProcess(allowTestAgent: hostless) == nil)
        var otherSimulator = launch
        otherSimulator.simulatorIdentifier = UUID()
        #expect(otherSimulator.captureSuspendedProcess(allowTestAgent: hostless) == nil)
        var stale = captured
        stale.process.startedSeconds -= 1
        try await stale.terminateIfStillSuspended()
        #expect(launch.captureSuspendedProcess(allowTestAgent: hostless) != nil)

        let completed = NativeExecutionOperations.Scope()
        completed.prepareTestHosts()
        completed.recordLaunch(launch)
        try await completed.finish()
        completed.cancel()
        completed.recordLaunch(launch)
        try await completed.finish()
        #expect(launch.captureSuspendedProcess(allowTestAgent: hostless) != nil)

        #expect(kill(process.processIdentifier, SIGCONT) == 0)
        for _ in 0..<100 where launch.captureSuspendedProcess(allowTestAgent: hostless) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(launch.captureSuspendedProcess(allowTestAgent: hostless) == nil)
        try await captured.terminateIfStillSuspended()
        #expect(process.isRunning)

        #expect(kill(process.processIdentifier, SIGSTOP) == 0)
        for _ in 0..<100 where launch.captureSuspendedProcess(allowTestAgent: hostless) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(launch.captureSuspendedProcess(allowTestAgent: hostless))
        let cancelled = NativeExecutionOperations.Scope()
        cancelled.prepareTestHosts()
        cancelled.recordLaunch(launch)
        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            cancelled.cancel()
            try await cancelled.finish()
        }
        try await cleanup.value
        var iterator = terminated.stream.makeAsyncIterator()
        #expect(await iterator.next() == SIGKILL)
        #expect(!process.isRunning)
    }

    @Test(arguments: [false, true]) func onlyASuccessfulLaunchCanContinue(failed: Bool) {
        let output = JSONValue.object([
            "buildErrors": .array(failed ? [.string("build failed")] : []),
            "processIdentifier": .number(.int(42)),
        ])
        #expect(NativeApplicationLaunch.processIdentifier(in: .succeeded(output)) == (failed ? nil : 42))
        #expect(NativeApplicationLaunch.processIdentifier(in: .failed) == nil)
    }

    @Test(arguments: [Int64(0), -1, Int64(Int32.max) + 1]) func invalidLaunchPIDsDoNotChangeCleanup(pid: Int64) {
        #expect(NativeApplicationLaunch.processIdentifier(in: .succeeded(.object([
            "buildErrors": .array([]), "processIdentifier": .number(.int(pid)),
        ]))) == nil)
    }

    @Test func onlyAStoppedUntracedAppInTheSelectedSimulatorCanResume() {
        let device = UUID()
        var process = NativeApplicationLaunch.ProcessSnapshot(
            executable: "/a/custom/device/set/\(device)/data/Containers/Bundle/Application/\(UUID())/Fixture.app/Fixture",
            startedSeconds: 10, startedMicroseconds: 0, stopped: true, traced: false)
        #expect(process.canResume(in: device))
        #expect(!process.canResume(in: UUID()))
        process.traced = true
        #expect(!process.canResume(in: device))
        process.traced = false
        process.stopped = false
        #expect(!process.canResume(in: device))
        process.stopped = true
        process.executable = "/Applications/Fixture.app/Contents/MacOS/Fixture"
        #expect(!process.canResume(in: device))
    }
}
