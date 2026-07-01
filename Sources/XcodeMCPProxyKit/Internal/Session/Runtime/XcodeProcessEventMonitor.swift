import Dispatch
import Foundation

#if canImport(AppKit)
import AppKit
#endif

final class XcodeProcessEventMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var notificationTokens: [NSObjectProtocol] = []
    private var exitSources: [pid_t: DispatchSourceProcess] = [:]
    private var didStartWorkspaceNotifications = false

    deinit {
        stop()
    }

    func startWorkspaceNotifications(
        trigger: @escaping @Sendable (_ reason: String) -> Void
    ) {
        #if canImport(AppKit)
        lock.lock()
        guard didStartWorkspaceNotifications == false else {
            lock.unlock()
            return
        }
        didStartWorkspaceNotifications = true
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        let launchToken = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
                trigger("workspace_launch")
            }
        }
        let terminateToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { _ in
            trigger("workspace_terminate")
        }

        lock.lock()
        notificationTokens.append(launchToken)
        notificationTokens.append(terminateToken)
        lock.unlock()
        #endif
    }

    func observeExit(
        processID: pid_t,
        trigger: @escaping @Sendable (_ reason: String) -> Void
    ) {
        lock.lock()
        if exitSources[processID] != nil {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeProcessSource(
            identifier: processID,
            eventMask: .exit,
            queue: DispatchQueue.global()
        )
        exitSources[processID] = source
        lock.unlock()

        source.setEventHandler {
            trigger("process_exit_\(processID)")
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.exitSources.removeValue(forKey: processID)
            self.lock.unlock()
        }
        source.resume()
    }

    func removeExitObserver(processID: pid_t) {
        lock.lock()
        let source = exitSources.removeValue(forKey: processID)
        lock.unlock()
        source?.cancel()
    }

    func stop() {
        #if canImport(AppKit)
        lock.lock()
        let tokens = notificationTokens
        notificationTokens.removeAll()
        didStartWorkspaceNotifications = false
        let sources = Array(exitSources.values)
        exitSources.removeAll()
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        for source in sources {
            source.cancel()
        }
        #else
        lock.lock()
        let sources = Array(exitSources.values)
        exitSources.removeAll()
        lock.unlock()
        for source in sources {
            source.cancel()
        }
        #endif
    }
}
