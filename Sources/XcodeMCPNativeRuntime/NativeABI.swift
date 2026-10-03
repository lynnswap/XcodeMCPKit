import ABIBridge
import ABIBridgeCore
import Foundation

@_silgen_name("ABIInvokeSwiftAsync")
nonisolated(nonsending) private func invokeNativeAsyncFrame(_ invocation: OpaquePointer) async

@unsafe
package struct NativeActionClass: ABIBridgeValue, BitwiseCopyable {
    package let metadata: UnsafeRawPointer
    package let conformance: UnsafeRawPointer

    package static let abiType: NativeType = try! .structure(named: "NativeActionClass", fields: [.pointer, .pointer])
}

@MainActor
@safe
final class NativeABI {
    private var valueTypes: [OpaquePointer] = unsafe []
    private var callInterfaces: [OpaquePointer] = unsafe []
    private var asyncInterfaces: [OpaquePointer] = unsafe []

    isolated deinit {
        for unsafe interface in unsafe asyncInterfaces { unsafe ABIReleaseSwiftAsyncCallInterface(interface) }
        for unsafe interface in unsafe callInterfaces { unsafe ABIReleaseSwiftCallInterface(interface) }
        for unsafe type in unsafe valueTypes.reversed() { unsafe ABIReleaseValueType(type) }
    }

    func require<T>(_ value: T?, failure: inout OpaquePointer?) throws -> T {
        guard let value else {
            let message = unsafe failure.map { unsafe String(cString: ABIResolutionFailureMessage($0)) } ?? "Native ABI preparation failed"
            if let error = unsafe failure { unsafe ABIReleaseResolutionFailure(error); unsafe failure = nil }
            throw NativeRuntimeError.invocation(message)
        }
        return value
    }

    func scalar(_ kind: Int32) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let type = try unsafe require(ABICreateScalarType(kind, &failure), failure: &failure)
        unsafe valueTypes.append(type)
        return unsafe type
    }

    func storage<T>(for type: T.Type, components: [OpaquePointer]) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let component: OpaquePointer
        if unsafe components.count == 1, let only = unsafe components.first {
            unsafe component = only
        } else {
            let fields = unsafe components.map(Optional.some)
            unsafe component = try require(fields.withUnsafeBufferPointer {
                unsafe ABICreateStructType($0.baseAddress, $0.count, &failure)
            }, failure: &failure)
            unsafe valueTypes.append(component)
        }
        let result = try unsafe require(ABICreateSwiftStorageType(component, MemoryLayout<T>.size, MemoryLayout<T>.alignment, &failure), failure: &failure)
        unsafe valueTypes.append(result)
        return unsafe result
    }

    func indirectStorage<T>(for type: T.Type) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let result = try unsafe require(ABICreateSwiftIndirectStorageType(MemoryLayout<T>.size, MemoryLayout<T>.alignment, &failure), failure: &failure)
        unsafe valueTypes.append(result)
        return unsafe result
    }

    func callInterface(result: OpaquePointer, parameters: [OpaquePointer]) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let parameters = unsafe parameters.map(Optional.some)
        let result = try unsafe require(parameters.withUnsafeBufferPointer {
            unsafe ABICreateSwiftCallInterface(result, $0.baseAddress, $0.count, &failure)
        }, failure: &failure)
        unsafe callInterfaces.append(result)
        return unsafe result
    }

    func asyncInterface(result: OpaquePointer, parameters: [OpaquePointer]) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let parameters = unsafe parameters.map(Optional.some)
        let result = try unsafe require(parameters.withUnsafeBufferPointer {
            unsafe ABICreateSwiftAsyncCallInterface(result, $0.baseAddress, $0.count, nil, false, false, &failure)
        }, failure: &failure)
        unsafe asyncInterfaces.append(result)
        return unsafe result
    }

    // The caller supplies the native declaration's nonthrowing ABI and live
    // argument storage. A successful invocation initializes one owned T.
    @unsafe func invoke<T>(symbol: ResolvedSymbol, interface: OpaquePointer,
                   arguments: [UnsafeMutableRawPointer?], context: UnsafeRawPointer? = nil,
                   returning: T.Type) throws -> T {
        var failure: OpaquePointer?
        let output = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { unsafe output.deallocate() }
        let success = unsafe symbol.withUnsafeAddress { address in
            arguments.withUnsafeBufferPointer {
                unsafe ABIUnsafeInvokeSwiftCallInterface(interface, ABIUnsafeFunctionAtAddress(address), output, $0.baseAddress, context, &failure)
            }
        }
        guard success else { return try unsafe require(nil as T?, failure: &failure) }
        return unsafe output.move()
    }

    // Async inputs and Swift self storage must stay live through completion;
    // cancellation does not abandon the active native async frame.
    @unsafe func invokeAsync<T>(symbol: ResolvedSymbol, interface: OpaquePointer,
                        arguments: [UnsafeMutableRawPointer?], context: UnsafeRawPointer?,
                        returning: T.Type) async throws -> T {
        var failure: OpaquePointer?
        let descriptor = try unsafe symbol.withUnsafeAddress {
            try unsafe require(ABICopySwiftAsyncDescriptor($0, &failure), failure: &failure)
        }
        defer { unsafe ABIReleaseSwiftAsyncDescriptor(descriptor) }
        let output = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { unsafe output.deallocate() }
        let invocation = try unsafe require(arguments.withUnsafeBufferPointer {
            unsafe ABICreateSwiftAsyncInvocation(interface, ABISwiftAsyncDescriptorFunction(descriptor), ABISwiftAsyncDescriptorContextSize(descriptor), output, $0.baseAddress, context, nil, &failure)
        }, failure: &failure)
        defer { withExtendedLifetime(symbol) { unsafe ABIReleaseSwiftAsyncInvocation(invocation) } }
        unsafe await invokeNativeAsyncFrame(invocation)
        return unsafe output.move()
    }
}
