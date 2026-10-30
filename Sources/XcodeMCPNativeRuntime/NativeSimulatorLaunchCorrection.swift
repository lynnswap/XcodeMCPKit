import ABIBridge
import Foundation

@safe
final class NativeSimulatorLaunchCorrection {
    private let initialization: NativeObjCMethodHook?
    private let completion: NativeObjCMethodHook?

    @MainActor init(ownership: NativeLaunchOwnership, onFailure: @escaping @Sendable (any Error) -> Void) throws {
        guard let launcherClass = NSClassFromString("IDELaunchiPhoneSimulatorLauncher") else {
            initialization = nil
            completion = nil
            return
        }
        let runtime = ABIRuntime.shared
        completion = try unsafe runtime.hookCalls(
            .objc(.method("launchCompleteWithAppPID:", as: ((Int32) -> Void).self)), on: launcherClass,
            onFailure: onFailure
        ) { call, pid in
            let launcher = try call.receiver
            guard let owned = ownership.launch(for: launcher) else {
                try call.proceed(pid)
                return
            }
            var launch = owned.launch
            launch.processIdentifier = pid
            owned.scope.recordLaunch(launch)
            try call.proceed(pid)
            try owned.scope.resumeTestHostIfNeeded(launch)
        }
        initialization = try unsafe runtime.hookMainActorInitializer(
            .objc(.method("initWithExtensionIdentifier:launchSession:", as: ((AnyObject?, AnyObject?) -> AnyObject?).self)),
            on: launcherClass, onFailure: onFailure,
            after: { launcher in
                guard let launcher, let session = try NativeApplicationLaunch.object(launcher, "launchSession") else { return }
                let launch = try NativeApplicationLaunch.read(session: session, processIdentifier: 0)
                guard launch.simulatorIdentifier != nil else { return }
                // XCTest assigns the tracker's session after creating its launcher.
                // Resolve ownership when the PID arrives, outside its Task context.
                ownership.registerLauncher(launcher, session: session,
                    scope: NativeExecutionOperations.scope, launch: launch)
            })
    }
}
