import ABIBridge
import ABIBridgeCore
import ABIBridgeCore.Backend
import Foundation

/// Reads Objective-C properties of native Xcode objects through their getters.
@safe
@MainActor
enum NativeObjCGetters {
    static func object(_ receiver: AnyObject, selector: String) throws -> AnyObject? {
        let get = try ABIRuntime.shared.object(receiver).resolveAndWait(.objc(.method(selector, as: (() -> AnyObject?).self)))
        return try unsafe get.unsafeInvoke()
    }

    static func boolean(_ receiver: AnyObject, selector: String) throws -> Bool {
        let get = try ABIRuntime.shared.object(receiver).resolveAndWait(.objc(.method(selector, as: (() -> Bool).self)))
        return try unsafe get.unsafeInvoke()
    }

    static func array<Value>(_ receiver: AnyObject, selector: String) throws -> [Value] {
        guard let value = try Self.object(receiver, selector: selector) else { return [] }
        guard let values = value as? [Value] else {
            throw NativeRuntimeError.unsupportedContract("The native \(selector) value is not an array of \(Value.self)")
        }
        return values
    }

    static func optionalString(_ receiver: AnyObject?, selector: String) throws -> String? {
        guard let receiver, let object = receiver as? NSObject,
              object.responds(to: NSSelectorFromString(selector)) else { return nil }
        let get = try ABIRuntime.shared.object(receiver).resolveAndWait(.objc(.method(selector, as: (() -> String?).self)))
        return try unsafe get.unsafeInvoke()
    }
}
