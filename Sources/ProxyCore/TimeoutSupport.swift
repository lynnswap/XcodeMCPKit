import Foundation
import NIO

package func makeRequestTimeout(_ seconds: TimeInterval) -> TimeAmount? {
    guard seconds > 0 else { return nil }
    let whole = Int64(seconds)
    let fractional = seconds - Double(whole)
    let nanos = Int64((fractional * 1_000_000_000).rounded())
    return .seconds(whole) + .nanoseconds(nanos)
}

package struct TimeoutError: Error {
    package init() {}
}
