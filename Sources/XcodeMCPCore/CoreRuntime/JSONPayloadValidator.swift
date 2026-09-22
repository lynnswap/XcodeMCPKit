import Foundation

package func isValidJSONPayload(_ data: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
        return false
    }
    return json is [String: Any] || json is [Any]
}
