import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NativeDebuggerReadinessTests {
    @Test func waitsForTheMatchingSessionsDebuggerAndConsole() async throws {
        let session = ReadinessSession()
        let other = ReadinessSession()
        other.processIdentifier = 99
        let debugger = ReadinessDebugger()
        debugger.console = NSObject()
        other.debugger = debugger
        session.executionEnvironment.currentLaunchSession = other
        let tracker = NativeExecutionTracker(ReadinessTracker(session))
        var finished = false
        let waiting = Task {
            try await tracker.waitForDebugger(processIdentifier: 42)
            finished = true
        }
        var wrongPID = other.pidReads.stream.makeAsyncIterator()
        _ = await wrongPID.next(isolation: MainActor.shared)
        #expect(!finished)
        session.executionEnvironment.currentLaunchSession = session
        var debugReads = session.debugReads.stream.makeAsyncIterator()
        _ = await debugReads.next(isolation: MainActor.shared)
        #expect(!finished)
        let pending = ReadinessDebugger()
        session.debugger = pending
        var consoleReads = pending.consoleReads.stream.makeAsyncIterator()
        _ = await consoleReads.next(isolation: MainActor.shared)
        #expect(!finished)
        pending.console = NSObject()
        try await waiting.value
        #expect(finished)
    }

    @Test func cancelledLaunchDoesNotWaitForAConsole() async {
        let session = ReadinessSession()
        let native = ReadinessTracker(session)
        native.operation.cancel()
        let tracker = NativeExecutionTracker(native)
        await #expect(throws: CancellationError.self) {
            try await tracker.waitForDebugger(processIdentifier: 42)
        }
    }

    @Test func aFinishedLaunchWithoutADebuggerFailsInsteadOfHandingOff() async {
        let session = ReadinessSession()
        let native = ReadinessTracker(session)
        native.operation.start()
        let tracker = NativeExecutionTracker(native)
        await #expect(throws: NativeRuntimeError.self) {
            try await tracker.waitForDebugger(processIdentifier: 42)
        }
    }
}

@MainActor
private final class ReadinessTracker: NSObject {
    @objc let operation = BlockOperation {}
    @objc let launchSession: ReadinessSession
    init(_ session: ReadinessSession) { launchSession = session }
}

@MainActor
private final class ReadinessSession: NSObject {
    @objc let launchParameters = ReadinessParameters()
    @objc let executionEnvironment = ReadinessEnvironment()
    @objc let runDestination: NSObject? = nil
    var processIdentifier: Int32 = 42
    var debugger: ReadinessDebugger?
    let pidReads = AsyncStream<Void>.makeStream()
    let debugReads = AsyncStream<Void>.makeStream()
    @objc var runnablePID: Int32 { pidReads.continuation.yield(()); return processIdentifier }
    @objc var currentDebugSession: ReadinessDebugger? { debugReads.continuation.yield(()); return debugger }
    override init() {
        super.init()
        executionEnvironment.currentLaunchSession = self
    }
}

@MainActor
private final class ReadinessEnvironment: NSObject {
    @objc weak var currentLaunchSession: ReadinessSession?
}

@MainActor
private final class ReadinessParameters: NSObject {
    @objc let selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
}

@MainActor
private final class ReadinessDebugger: NSObject {
    var console: NSObject?
    let consoleReads = AsyncStream<Void>.makeStream()
    @objc var debuggerConsoleAdaptor: NSObject? { consoleReads.continuation.yield(()); return console }
}
