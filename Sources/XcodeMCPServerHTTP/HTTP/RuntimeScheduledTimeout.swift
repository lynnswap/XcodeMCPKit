import NIOCore

final class RuntimeScheduledTimeout: @unchecked Sendable {
    private let cancelImpl: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancelImpl = cancel
    }

    func cancel() {
        cancelImpl()
    }

    static func schedule(
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
