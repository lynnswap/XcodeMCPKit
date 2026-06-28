import NIO

package final class RuntimeScheduledTimeout: @unchecked Sendable {
    private let cancelImpl: @Sendable () -> Void

    package init(cancel: @escaping @Sendable () -> Void) {
        self.cancelImpl = cancel
    }

    package func cancel() {
        cancelImpl()
    }

    package static func schedule(
        on eventLoop: EventLoop,
        in delay: TimeAmount,
        operation: @escaping @Sendable () -> Void
    ) -> RuntimeScheduledTimeout {
        let task = eventLoop.scheduleTask(in: delay) {
            operation()
        }
        return RuntimeScheduledTimeout {
            task.cancel()
        }
    }
}
