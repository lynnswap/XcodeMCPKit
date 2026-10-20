import ABIBridge
import Foundation
import Synchronization

@safe
@MainActor
final class NativeTestableStateCorrection {
    private let callback: NativeTestableStateCallback
    private let hook: NativeObjCMethodHook

    init() throws {
        guard let stateClass = NSClassFromString("_IDETestableState") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's testable-state class is unavailable")
        }
        let runtime = ABIRuntime.shared
        // Preparing the getter first lets the class synthesize its native
        // invalidation methods before the creation hook is installed.
        let callback = NativeTestableStateCallback(isValid: try runtime.resolveObjCMethodAndWait(
            on: stateClass, selector: "isValid", as: (() -> Bool).self))
        self.callback = callback
        // Xcode's deferred loading callback can run after state invalidation.
        // A provider created then misses its owner's invalidation cleanup.
        hook = try unsafe runtime.hookMethod(
            on: stateClass, selector: "createNoticeProviderForWorkspace:", as: ((AnyObject?) -> Void).self,
            onFailure: { callback.recordFailure($0) }
        ) { call, workspace in
            do {
                guard try unsafe callback.isValid.unsafeInvoke(on: call.receiver) else { return }
                try call.proceed(workspace)
            } catch {
                // Throwing out of the callback would let ABIBridge forward a
                // failed validity check to the native implementation.
                callback.recordFailure(error)
            }
        }
    }

    func checkFailure() throws {
        try callback.checkFailure()
    }

    /// A recorded failure means a provider may have missed its owner's cleanup; the process stays unreliable.
    var failure: (any Error)? { callback.recordedFailure }
}

// This receiver-independent getter has immutable signature/image data, no code
// owner, and separate argument storage per call. Only the first error is mutable;
// callbacks synchronize it without changing the native caller's thread.
@safe
private final class NativeTestableStateCallback: @unchecked Sendable {
    let isValid: NativeObjCMethod<Bool>
    private let failure = Mutex<(any Error)?>(nil)

    init(isValid: NativeObjCMethod<Bool>) {
        self.isValid = isValid
    }

    func recordFailure(_ error: any Error) {
        failure.withLock { if $0 == nil { $0 = error } }
    }

    func checkFailure() throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }

    var recordedFailure: (any Error)? { failure.withLock { $0 } }
}
