import Foundation
import NIO
import NIOConcurrencyHelpers

final class NotificationHub: Sendable {
    private let sseHub = SSEHub()

    var hasClients: Bool {
        hasSseClients
    }

    var hasSseClients: Bool {
        sseHub.hasClients
    }

    func addSse(_ channel: Channel) {
        sseHub.add(channel)
    }

    func waitForSSEClient() async throws {
        try await sseHub.waitForClient()
    }

    func removeSse(_ channel: Channel) {
        sseHub.remove(channel)
    }

    func broadcast(_ data: Data) {
        sseHub.broadcast(data)
    }

    func closeAll() {
        sseHub.closeAll()
    }
}
