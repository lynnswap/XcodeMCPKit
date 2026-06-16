import NIOConcurrencyHelpers

package final class ServerRequestTracker: Sendable {
    private let upstreamByIDKey = NIOLockedValueBox<[String: Int]>([:])

    package init() {}

    package func record(idKey: String, upstreamIndex: Int) {
        upstreamByIDKey.withLockedValue { upstreamByIDKey in
            upstreamByIDKey[idKey] = upstreamIndex
        }
    }

    package func consume(idKey: String) -> Int? {
        upstreamByIDKey.withLockedValue { upstreamByIDKey in
            upstreamByIDKey.removeValue(forKey: idKey)
        }
    }
}
