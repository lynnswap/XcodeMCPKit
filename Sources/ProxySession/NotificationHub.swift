import Foundation
import NIO
import NIOConcurrencyHelpers

package final class NotificationHub: Sendable {
    private let sseHub = SSEHub()

    package var hasClients: Bool {
        hasSseClients
    }

    package var hasSseClients: Bool {
        sseHub.hasClients
    }

    package func addSse(_ channel: Channel) {
        sseHub.add(channel)
    }

    package func removeSse(_ channel: Channel) {
        sseHub.remove(channel)
    }

    package func broadcast(_ data: Data) {
        sseHub.broadcast(data)
    }

    package func closeAll() {
        sseHub.closeAll()
    }
}
