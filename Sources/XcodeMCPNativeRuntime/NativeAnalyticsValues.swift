import ABIBridge
import Foundation

// These representations describe compiler-known standard-library values, not
// private Xcode structs. The compiler owns their copying and destruction.
struct NativeAnalyticsBoolean: ABIBridgeSwiftValue {
    let value: Bool?
    static let swiftABIType: NativeType = .uint8
}

struct NativeAnalyticsInteger: ABIBridgeSwiftValue {
    let value: Int?
    static let swiftABIType: NativeType = try! .structure(named: "OptionalInt", fields: [.int, .uint8])
}

struct NativeAnalyticsDictionary: ABIBridgeSwiftValue {
    let value: [String: Any]
    static let swiftABIType: NativeType = .pointer
}
