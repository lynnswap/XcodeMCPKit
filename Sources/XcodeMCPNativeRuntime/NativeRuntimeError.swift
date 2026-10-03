import Foundation

package enum NativeRuntimeError: Error, CustomStringConvertible, Sendable {
    case unavailable(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case unsupportedContract(String)
    case invocation(String)

    package var description: String {
        switch self {
        case .unavailable(let message), .invalidRequest(let message), .methodNotFound(let message),
             .unsupportedContract(let message), .invocation(let message):
            return message
        }
    }
}
