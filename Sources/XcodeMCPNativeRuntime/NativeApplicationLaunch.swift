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

    struct ProcessSnapshot: Equatable, Sendable {
        var executable: String
        var startedSeconds: Int64
        var startedMicroseconds: Int32
        var stopped: Bool
        var traced: Bool

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
}

// Xcode assigns the launch session after creating its tracker. Read it only
// after the native producer has drained, on the actor that owns Xcode's models.
@safe
final class NativeExecutionTracker: @unchecked Sendable {
    private let tracker: AnyObject

    init(_ tracker: AnyObject) { self.tracker = tracker }

    @MainActor func launch() throws -> NativeApplicationLaunch? {
        guard let session = try Self.object(tracker, "launchSession") else { return nil }
        let pid = try ABIRuntime.shared.object(session).resolveAndWait(.objc(.method("runnablePID", as: (() -> Int32).self)))
        let processIdentifier = try unsafe pid.unsafeInvoke()
        guard processIdentifier > 0 else { return nil }
        let parameters = try Self.object(session, "launchParameters")
        let debugger = try parameters.flatMap { try Self.object($0, "selectedDebuggerIdentifier") as? String }
        var simulator: UUID?
        if let destination = try Self.object(session, "runDestination"),
           let sdk = try Self.object(destination, "targetSDK"),
           let name = try Self.object(sdk, "canonicalName") as? String,
           ["iphonesimulator", "appletvsimulator", "watchsimulator", "xrsimulator"].contains(where: name.hasPrefix),
           let device = try Self.object(destination, "targetDevice"),
           let identifier = try Self.object(device, "identifier") as? String {
            simulator = UUID(uuidString: identifier)
        }
        return NativeApplicationLaunch(processIdentifier: processIdentifier,
            debuggerIdentifier: debugger, simulatorIdentifier: simulator)
    }

    @MainActor private static func object(_ receiver: AnyObject, _ selector: String) throws -> AnyObject? {
        let get = try ABIRuntime.shared.object(receiver).resolveAndWait(.objc(.method(selector, as: (() -> AnyObject?).self)))
        return try unsafe get.unsafeInvoke()
    }
}
