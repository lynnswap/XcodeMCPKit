import ABIBridge
import Foundation
import ObjectiveC
import Synchronization

// The downloader sends product lookups through GCD. A request-owned receiver
// preserves selection there without task-local or process-global state.
@safe
final class NativeAnalyticsProductManager: NSObject {
    private let manager: AnyObject
    private let bundleIdentifier: String
    private let familyIdentifier: String
    private let failure = Mutex<(any Error)?>(nil)

    init(manager: AnyObject, bundleIdentifier: String, familyIdentifier: String) {
        self.manager = manager
        self.bundleIdentifier = bundleIdentifier
        self.familyIdentifier = familyIdentifier
        super.init()
    }

    static func establishNativeProtocol() throws {
        guard let nativeProtocol = unsafe objc_getProtocol("DVTProductManagerProtocol") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's product-manager protocol is unavailable")
        }
        _ = unsafe class_addProtocol(Self.self, nativeProtocol)
    }

    @objc var products: NSArray {
        do {
            let runtime = ABIRuntime.shared
            let getter = try runtime.object(manager).method(selector: "products", as: (() -> NSArray).self)
            let original = try unsafe getter.unsafeInvoke()
            let selected = try original.filter { item in
                let product = item as AnyObject
                guard try Self.bundleIdentifier(for: product) == bundleIdentifier else { return true }
                return try Self.familyIdentifier(for: product) == familyIdentifier
            }
            return NSArray(array: selected)
        } catch {
            // Objective-C's getter cannot throw. The async caller checks this
            // failure before interpreting the native result or native error.
            failure.withLock { if $0 == nil { $0 = error } }
            return NSArray()
        }
    }

    func checkFailure() throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { manager }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (manager as? NSObject)?.responds(to: selector) == true
    }

    private static func bundleIdentifier(for product: AnyObject) throws -> String? {
        let identifier = try requiredObject(product, selector: "identifier")
        let getter = try ABIRuntime.shared.object(identifier).method(selector: "bundleIdentifier", as: (() -> String?).self)
        return try unsafe getter.unsafeInvoke()
    }

    private static func familyIdentifier(for product: AnyObject) throws -> String? {
        let identifier = try requiredObject(product, selector: "identifier")
        let category = try requiredObject(identifier, selector: "productCategory")
        let getter = try ABIRuntime.shared.object(category).method(selector: "platform", as: (() -> AnyObject?).self)
        guard let platform = try unsafe getter.unsafeInvoke() else { return nil }
        return try platformFamilyIdentifier(platform)
    }

    static func platformFamilyIdentifier(_ platform: AnyObject) throws -> String {
        let family = try requiredObject(platform, selector: "family")
        let getter = try ABIRuntime.shared.object(family).method(selector: "identifier", as: (() -> String).self)
        return try unsafe getter.unsafeInvoke()
    }

    private static func requiredObject(_ object: AnyObject, selector: String) throws -> AnyObject {
        let getter = try ABIRuntime.shared.object(object).method(selector: selector, as: (() -> AnyObject).self)
        return try unsafe getter.unsafeInvoke()
    }
}
