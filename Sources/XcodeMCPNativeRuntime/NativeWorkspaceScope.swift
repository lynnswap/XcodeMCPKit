import ABIBridge
import ABIBridgeCore
import Foundation

@safe
@MainActor
final class NativeWorkspaceScope {
    private let runtime = ABIRuntime.shared
    private let abi = NativeABI()
    private let entry: ResolvedSymbol
    private let base: ResolvedSymbol
    private let associated: ResolvedSymbol
    private let protocols: [ResolvedSymbol]
    private let interface: OpaquePointer

    init(installation: NativeXcodeInstallation) async throws {
        let core = URL(fileURLWithPath: "/usr/lib/swift/libswiftCore.dylib")
        entry = try await runtime.resolve(.init(name: "swift_getAssociatedTypeWitness", language: .c), in: .path(core))
        let foundation = installation.framework("DVTFoundation", in: "SharedFrameworks")
        base = try await runtime.resolve(.init(name: "protocol requirements base descriptor for DVTFoundation.DVTStatelessAction", language: .swift, kind: .data), in: .path(foundation))
        associated = try await runtime.resolve(.init(name: "associated type descriptor for DVTFoundation.DVTStatelessAction.Input", language: .swift, kind: .data), in: .path(foundation))
        let kit = installation.framework("IDEKit")
        var descriptors: [ResolvedSymbol] = []
        for name in ["IDEKit.IDEWorkspaceStatefulActionInputV2", "IDEKit.IDEWorkspaceStatefulActionInput"] {
            descriptors.append(try await runtime.resolve(.init(name: "protocol descriptor for \(name)", language: .swift, kind: .data), in: .path(kit)))
        }
        protocols = descriptors
        let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
        let word = try unsafe abi.scalar(Int32(ABIValueUInt64))
        let response = try unsafe abi.storage(for: NativeMetadataResponse.self, components: [pointer, word])
        unsafe (interface = try abi.callInterface(result: response, parameters: [word, pointer, pointer, pointer, pointer]))
    }

    func inputType(for action: NativeActionClass) throws -> Any.Type {
        var request: UInt64 = 0
        var witness = unsafe action.conformance
        var metadata = unsafe action.metadata
        let result: NativeMetadataResponse = try unsafe base.withUnsafeAddress { baseAddress in
            try unsafe associated.withUnsafeAddress { associatedAddress in
                var baseAddress = unsafe baseAddress
                var associatedAddress = unsafe associatedAddress
                return try withUnsafeMutablePointer(to: &request) { request in
                    try withUnsafeMutablePointer(to: &witness) { witness in
                        try withUnsafeMutablePointer(to: &metadata) { metadata in
                            try withUnsafeMutablePointer(to: &baseAddress) { base in
                                try withUnsafeMutablePointer(to: &associatedAddress) { associated in
                                    try unsafe abi.invoke(symbol: entry, interface: interface,
                                                   arguments: [UnsafeMutableRawPointer(request), UnsafeMutableRawPointer(witness), UnsafeMutableRawPointer(metadata), UnsafeMutableRawPointer(base), UnsafeMutableRawPointer(associated)],
                                                   returning: NativeMetadataResponse.self)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard let input = unsafe result.metadata else {
            throw NativeRuntimeError.unsupportedContract("Native action input metadata is unavailable")
        }
        return unsafe unsafeBitCast(input, to: Any.Type.self)
    }

    func isWorkspaceScoped(_ action: NativeActionClass) async throws -> Bool {
        let input = unsafe unsafeBitCast(try inputType(for: action), to: UnsafeRawPointer.self)
        let conforms = try unsafe await runtime.cFunction(named: "swift_conformsToProtocol", as: ((UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?).self)
        for descriptor in protocols {
            if try unsafe descriptor.withUnsafeAddress({ try unsafe conforms.unsafeInvoke(input, $0) }) != nil {
                return true
            }
        }
        return false
    }
}
