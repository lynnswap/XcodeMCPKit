import Foundation
import NIOConcurrencyHelpers
import XcodeMCPProxyRuntimeContract

final class ProxyRuntimeEventSource: Sendable {
    private struct Subscriber: Sendable {
        let id: UUID
        let receive: @Sendable (ProxyRuntimeEvent) -> Void
    }

    private enum Phase: Sendable {
        case waiting
        case subscribed(Subscriber)
        case detached
        case finished
    }

    private let phase = NIOLockedValueBox<Phase>(.waiting)

    func subscribe(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void {
        let subscriber = Subscriber(id: UUID(), receive: receive)
        phase.withLockedValue { phase in
            guard case .waiting = phase else {
                preconditionFailure("runtime event source accepts exactly one subscriber")
            }
            phase = .subscribed(subscriber)
        }
        return { [self] in
            detach(subscriberID: subscriber.id)
        }
    }

    func emit(_ event: ProxyRuntimeEvent) {
        phase.withLockedValue { phase in
            switch phase {
            case .waiting:
                preconditionFailure("runtime emitted an event before HTTP subscribed")
            case .subscribed(let subscriber):
                subscriber.receive(event)
            case .detached, .finished:
                break
            }
        }
    }

    func finish() {
        phase.withLockedValue { $0 = .finished }
    }

    private func detach(subscriberID: UUID) {
        phase.withLockedValue { phase in
            guard case .subscribed(let subscriber) = phase,
                subscriber.id == subscriberID
            else {
                return
            }
            phase = .detached
        }
    }
}
