import ABIBridge
import Foundation

// These representations describe compiler-known standard-library values, not
// private Xcode structs. The compiler owns their copying and destruction.
struct NativeAnalyticsBoolean: ABIBridgeSwiftValue {
    let value: Bool?
    static let swiftABIType: NativeType = .uint8
}
