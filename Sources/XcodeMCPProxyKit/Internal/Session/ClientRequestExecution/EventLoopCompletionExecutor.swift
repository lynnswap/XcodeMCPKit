import NIO

final class EventLoopCompletionExecutor: @unchecked Sendable {
    private let executeImpl: (EventLoop, @escaping () -> Void) -> Void

    init(_ execute: @escaping (EventLoop, @escaping () -> Void) -> Void) {
        self.executeImpl = execute
    }

    func execute(on eventLoop: EventLoop, _ operation: @escaping () -> Void) {
        executeImpl(eventLoop, operation)
    }

    static let eventLoop = EventLoopCompletionExecutor { eventLoop, operation in
        eventLoop.execute(operation)
    }
}
