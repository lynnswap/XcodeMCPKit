import ABIBridge
import AppKit
import Foundation
import ObjectiveC
import XcodeMCPWire

@MainActor
enum NativeErrorPresentation {
    @TaskLocal static var capture: Capture?

    @MainActor
    final class Capture {
        private(set) var errors: [NSError] = []

        func addingDiagnostics(to result: JSONValue) -> JSONValue {
            guard !errors.isEmpty, case .object(var fields) = result else { return result }
            let existing: [JSONValue]
            if case .array(let content) = fields["content"] { existing = content }
            else { existing = [] }
            fields["content"] = .array(existing + errors.map {
                .object(["type": .string("text"), "text": .string($0.description)])
            })
            fields["isError"] = .bool(true)
            return .object(fields)
        }

        fileprivate func record(_ error: NSError) {
            errors.append(error)
        }
    }

    static func report(_ error: NSError) {
        capture?.record(error)
        reportBackground("Native error presentation suppressed: \(error)")
    }

    static func reportBackground(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }

    static func install(on application: NSApplication) throws {
        let name = "XcodeMCPNoninteractiveApplication"
        guard let original = object_getClass(application) else {
            throw NativeRuntimeError.unavailable("The native application has no Objective-C class")
        }
        if let installed = NSClassFromString(name), application.isKind(of: installed) { return }

        let subclass: AnyClass
        if let existing = NSClassFromString(name) {
            guard class_getSuperclass(existing) === original else {
                throw NativeRuntimeError.unavailable("The noninteractive application class has a different superclass")
            }
            subclass = existing
        } else {
            guard let allocated = name.withCString({ unsafe objc_allocateClassPair(original, $0, 0) }) else {
                throw NativeRuntimeError.unavailable("Cannot create the noninteractive native application class")
            }
            var implementations: [IMP] = unsafe []
            do {
                let synchronous: @convention(block) (AnyObject, NSError) -> Bool = { _, error in
                    MainActor.assumeIsolated {
                        report(error)
                        return false
                    }
                }
                unsafe implementations.append(try addMethod("presentError:", block: synchronous, to: allocated, superclass: original))

                let sheet: @convention(block) (
                    AnyObject, NSError, NSWindow?, AnyObject?, Selector?, UnsafeMutableRawPointer?
                ) -> Void = { _, error, _, delegate, selector, context in
                    MainActor.assumeIsolated {
                        report(error)
                        guard let delegate, let selector else { return }
                        do {
                            let completion = try unsafe ABIRuntime.shared.object(delegate).method(
                                selector: NSStringFromSelector(selector),
                                as: ((Bool, UnsafeMutableRawPointer?) -> Void).self
                            )
                            try unsafe completion.unsafeInvoke(false, context)
                        } catch {
                            report(error as NSError)
                        }
                    }
                }
                unsafe implementations.append(try addMethod(
                    "presentError:modalForWindow:delegate:didPresentSelector:contextInfo:",
                    block: sheet, to: allocated, superclass: original
                ))
                objc_registerClassPair(allocated)
                subclass = allocated
            } catch {
                objc_disposeClassPair(allocated)
                unsafe implementations.forEach { unsafe imp_removeBlock($0) }
                throw error
            }
        }

        // The host still needs IDEApplication's behavior. A subclass with no
        // instance storage overrides only AppKit's public error-presentation API.
        object_setClass(application, subclass)
    }

    private static func addMethod(
        _ name: String, block: Any, to subclass: AnyClass, superclass: AnyClass
    ) throws -> IMP {
        let selector = NSSelectorFromString(name)
        guard let original = unsafe class_getInstanceMethod(superclass, selector),
              let encoding = unsafe method_getTypeEncoding(original) else {
            throw NativeRuntimeError.unavailable("AppKit error-presentation method '\(name)' is unavailable")
        }
        let implementation = unsafe imp_implementationWithBlock(block)
        guard unsafe class_addMethod(subclass, selector, implementation, encoding) else {
            unsafe imp_removeBlock(implementation)
            throw NativeRuntimeError.unavailable("Cannot override AppKit error-presentation method '\(name)'")
        }
        return unsafe implementation
    }
}
