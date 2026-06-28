import NIO

final class EventLoopCompletionExecutor: @unchecked Sendable {
    private let executeImpl: @Sendable (EventLoop, @escaping @Sendable () -> Void) -> Void

    init(_ execute: @escaping @Sendable (EventLoop, @escaping @Sendable () -> Void) -> Void) {
        self.executeImpl = execute
    }

    func execute(on eventLoop: EventLoop, _ operation: @escaping @Sendable () -> Void) {
        executeImpl(eventLoop, operation)
    }

    static let eventLoop = EventLoopCompletionExecutor { eventLoop, operation in
        eventLoop.execute(operation)
    }
}
