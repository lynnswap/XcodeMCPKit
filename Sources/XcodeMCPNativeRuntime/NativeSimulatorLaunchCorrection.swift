import ABIBridge
import Foundation

@safe
final class NativeSimulatorLaunchCorrection {
    private let hook: NativeObjCMethodHook?

    @MainActor init() throws {
        guard let launcherClass = NSClassFromString("IDELaunchiPhoneSimulatorLauncher") else {
            hook = nil
            return
        }
        hook = try unsafe ABIRuntime.shared.hookMainActorInitializer(
            .objc(.method("initWithExtensionIdentifier:launchSession:", as: ((AnyObject?, AnyObject?) -> AnyObject?).self)),
            on: launcherClass,
            onFailure: { NativeExecutionOperations.scope?.recordFailure($0) },
            after: { launcher in
                guard let launcher, let scope = NativeExecutionOperations.scope,
                      let session = try NativeApplicationLaunch.object(launcher, "launchSession") else { return }
                let template = try NativeApplicationLaunch.read(session: session, processIdentifier: 0)
                guard template.simulatorIdentifier != nil else { return }
                // The native PID callback can run off the request's Task and
                // before Xcode assigns runnablePID to its launch session.
                let hook = try unsafe ABIRuntime.shared.object(launcher).hookCalls(
                    .objc(.method("launchCompleteWithAppPID:", as: ((Int32) -> Void).self)),
                    onFailure: { [weak scope] in scope?.recordFailure($0) }
                ) { [weak scope] call, pid in
                    var launch = template
                    launch.processIdentifier = pid
                    scope?.recordLaunch(launch)
                    try call.proceed(pid)
                }
                scope.retainLaunchHook(hook)
            })
    }
}
