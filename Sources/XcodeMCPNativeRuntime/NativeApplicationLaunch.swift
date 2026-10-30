import ABIBridge
import Darwin
import Foundation
import XcodeMCPWire

@safe
struct NativeApplicationLaunch: Sendable {
    var processIdentifier: Int32
    var debuggerIdentifier: String?
    var simulatorIdentifier: UUID?

    static func processIdentifier(in outcome: NativeToolOutcome) -> Int32? {
        guard case .succeeded(.object(let output)) = outcome,
              case .array(let errors)? = output["buildErrors"], errors.isEmpty,
              case .number(.int(let value))? = output["processIdentifier"],
              let pid = Int32(exactly: value), pid > 0 else { return nil }
        return pid
    }

    func resumeIfStopped() throws {
        guard debuggerIdentifier?.isEmpty != false, let simulatorIdentifier,
              let process = Self.process(processIdentifier),
              process.canResume(in: simulatorIdentifier),
              let current = Self.process(processIdentifier), current == process else { return }
        if kill(processIdentifier, SIGCONT) != 0, errno != ESRCH {
            throw NativeRuntimeError.invocation("Resuming the simulator app (pid \(processIdentifier)) failed: errno \(errno)")
        }
    }

    func captureSuspendedProcess() -> CapturedProcess? {
        guard processIdentifier > 0, let simulatorIdentifier,
              let process = Self.process(processIdentifier), process.canResume(in: simulatorIdentifier) else { return nil }
        return CapturedProcess(launch: self, process: process)
    }

    struct CapturedProcess: Sendable {
        var launch: NativeApplicationLaunch
        var process: ProcessSnapshot

        func terminateIfStillSuspended() async throws {
            guard let captured = launch.captureSuspendedProcess(), captured.process == process else { return }
            // A suspended app cannot handle SIGTERM. Its native launch session
            // may already be invalidated without ever receiving the app's PID.
            if kill(launch.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                throw NativeRuntimeError.invocation("Stopping the cancelled simulator app (pid \(launch.processIdentifier)) failed: errno \(errno)")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while let current = NativeApplicationLaunch.process(launch.processIdentifier), current.isSameProcess(as: process) {
                guard ContinuousClock.now < deadline else {
                    throw NativeRuntimeError.invocation("The cancelled simulator app (pid \(launch.processIdentifier)) did not terminate")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    struct ProcessSnapshot: Equatable, Sendable {
        var executable: String
        var startedSeconds: Int64
        var startedMicroseconds: Int32
        var stopped: Bool
        var traced: Bool

        func isSameProcess(as other: Self) -> Bool {
            executable == other.executable && startedSeconds == other.startedSeconds && startedMicroseconds == other.startedMicroseconds
        }

        func canResume(in simulator: UUID) -> Bool {
            guard stopped, !traced else { return false }
            let parts = URL(fileURLWithPath: executable).standardizedFileURL.pathComponents
            guard let index = parts.firstIndex(where: { UUID(uuidString: $0) == simulator }) else { return false }
            return Array(parts.dropFirst(index + 1).prefix(4)) == ["data", "Containers", "Bundle", "Application"]
        }
    }

    private static func process(_ pid: Int32) -> ProcessSnapshot? {
        var info = unsafe kinfo_proc()
        var size = unsafe MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard unsafe sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard unsafe proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return unsafe ProcessSnapshot(executable: String(cString: path),
            startedSeconds: Int64(info.kp_proc.p_starttime.tv_sec),
            startedMicroseconds: info.kp_proc.p_starttime.tv_usec,
            stopped: Int32(info.kp_proc.p_stat) == SSTOP, traced: info.kp_proc.p_flag & P_TRACED != 0)
    }

    @MainActor static func read(session: AnyObject, processIdentifier: Int32) throws -> Self {
        let parameters = try object(session, "launchParameters")
        let debugger = try parameters.flatMap { try object($0, "selectedDebuggerIdentifier") as? String }
        var simulator: UUID?
        if let destination = try object(session, "runDestination"),
           let sdk = try object(destination, "targetSDK"),
           let name = try object(sdk, "canonicalName") as? String,
           ["iphonesimulator", "appletvsimulator", "watchsimulator", "xrsimulator"].contains(where: name.hasPrefix),
           let device = try object(destination, "targetDevice"),
           let identifier = try object(device, "identifier") as? String {
            simulator = UUID(uuidString: identifier)
        }
        return Self(processIdentifier: processIdentifier, debuggerIdentifier: debugger, simulatorIdentifier: simulator)
    }

    @MainActor static func object(_ receiver: AnyObject, _ selector: String) throws -> AnyObject? {
        let get = try ABIRuntime.shared.object(receiver).resolveAndWait(.objc(.method(selector, as: (() -> AnyObject?).self)))
        return try unsafe get.unsafeInvoke()
    }
}

// Xcode assigns the launch session after creating its tracker. Read it only
// after the native producer has drained, on the actor that owns Xcode's models.
@safe
final class NativeExecutionTracker: @unchecked Sendable {
    private let tracker: AnyObject

    init(_ tracker: AnyObject) { self.tracker = tracker }

    @MainActor func cancel() throws {
        let cancel = try ABIRuntime.shared.object(tracker).resolveAndWait(.objc(.method("cancel", as: (() -> Void).self)))
        try unsafe cancel.unsafeInvoke()
    }

    @MainActor func launch() throws -> NativeApplicationLaunch? {
        guard let session = try NativeApplicationLaunch.object(tracker, "launchSession") else { return nil }
        let processIdentifier = try pid(in: session)
        guard processIdentifier > 0 else { return nil }
        return try NativeApplicationLaunch.read(session: session, processIdentifier: processIdentifier)
    }

    @MainActor func waitForDebugger(processIdentifier: Int32) async throws {
        guard let session = try NativeApplicationLaunch.object(tracker, "launchSession") else {
            throw NativeRuntimeError.invocation("The launch session disappeared before debugger preparation")
        }
        let launch = try NativeApplicationLaunch.read(session: session, processIdentifier: processIdentifier)
        guard launch.debuggerIdentifier?.isEmpty == false else { return }
        guard let operation = try NativeApplicationLaunch.object(tracker, "operation") as? Operation,
              let environment = try NativeApplicationLaunch.object(session, "executionEnvironment") else {
            throw NativeRuntimeError.unsupportedContract("The debugger launch has no execution operation or environment")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while true {
            try Task.checkCancellation()
            if operation.isCancelled { throw CancellationError() }
            if let current = try NativeApplicationLaunch.object(environment, "currentLaunchSession"),
               try pid(in: current) == processIdentifier,
               let debugger = try NativeApplicationLaunch.object(current, "currentDebugSession"),
               try NativeApplicationLaunch.object(debugger, "debuggerConsoleAdaptor") != nil {
                return
            }
            guard !operation.isFinished else {
                throw NativeRuntimeError.invocation("The launch ended before the debugger became ready")
            }
            guard ContinuousClock.now < deadline else {
                throw NativeRuntimeError.invocation("The debugger did not become ready for pid \(processIdentifier) within 60 seconds")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func pid(in session: AnyObject) throws -> Int32 {
        let pid = try ABIRuntime.shared.object(session).resolveAndWait(.objc(.method("runnablePID", as: (() -> Int32).self)))
        return try unsafe pid.unsafeInvoke()
    }
}
