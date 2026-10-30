import Foundation
import Synchronization

@safe
final class NativeLaunchOwnership: Sendable {
    // Native objects cross callbacks only as weak identities; their model state
    // remains on its owning actor.
    private struct Entry: @unchecked Sendable {
        weak var object: AnyObject?
        weak var scope: NativeExecutionOperations.Scope?
        weak var session: AnyObject?
        var launch: NativeApplicationLaunch?
    }

    private let entries = Mutex<[ObjectIdentifier: Entry]>([:])

    func register(_ object: AnyObject, scope: NativeExecutionOperations.Scope) {
        entries.withLock {
            $0 = $0.filter { $0.value.object != nil && ($0.value.scope != nil || $0.value.session != nil) }
            $0[ObjectIdentifier(object)] = Entry(object: object, scope: scope)
        }
    }

    func registerLauncher(_ launcher: AnyObject, session: AnyObject,
                          scope: NativeExecutionOperations.Scope?, launch: NativeApplicationLaunch) {
        entries.withLock {
            $0[ObjectIdentifier(launcher)] = Entry(object: launcher, scope: scope, session: session, launch: launch)
        }
    }

    func launch(for launcher: AnyObject) -> (scope: NativeExecutionOperations.Scope, launch: NativeApplicationLaunch)? {
        entries.withLock { entries in
            guard let entry = entries[ObjectIdentifier(launcher)], entry.object === launcher,
                  let launch = entry.launch else { return nil }
            var scope = entry.scope
            if scope == nil, let session = entry.session,
               let owner = entries[ObjectIdentifier(session)], owner.object === session {
                scope = owner.scope
            }
            guard let scope, !scope.launchesFinished else { return nil }
            return (scope, launch)
        }
    }

    func scope(for object: AnyObject) -> NativeExecutionOperations.Scope? {
        entries.withLock { entries in
            let identifier = ObjectIdentifier(object)
            guard let entry = entries[identifier], entry.object === object,
                  let scope = entry.scope, !scope.launchesFinished else {
                entries[identifier] = nil
                return nil
            }
            return scope
        }
    }
}
