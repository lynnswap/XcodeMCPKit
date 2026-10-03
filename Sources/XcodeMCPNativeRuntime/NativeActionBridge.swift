import ABIBridge
import ABIBridgeCore
import Foundation

@safe
@MainActor
final class NativeActionBridge {
    private let runtime = ABIRuntime.shared
    private let installation: NativeXcodeInstallation
    private let abi = NativeABI()
    private var streamEntry: ResolvedSymbol?
    private var schemaEntry: ResolvedSymbol?
    private var streamInterface: OpaquePointer?
    private var schemaInterface: OpaquePointer?

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    func registeredActions() throws -> [String: AnyObject] {
        guard let type = NSClassFromString("DVTFoundation.DVTStatelessActionManager") else {
            throw NativeRuntimeError.unavailable("Xcode's native action registry is unavailable")
        }
        let getter = try runtime.object(type as AnyObject).method(selector: "shared", as: (() -> AnyObject).self)
        let manager = try unsafe getter.unsafeInvoke()
        let actions = try runtime.object(manager).method(selector: "allActionMetadata", as: (() -> NSDictionary).self)
        guard let values = try unsafe actions.unsafeInvoke() as? [String: AnyObject] else {
            throw NativeRuntimeError.unsupportedContract("Native action registry has an unsupported representation")
        }
        return values
    }

    func actionClass(for metadata: AnyObject) async throws -> NativeActionClass {
        let getter = try unsafe await runtime.object(metadata).getter(
            named: "actionClass.getter : DVTFoundation.DVTStatelessAction.Type", as: NativeActionClass.self
        )
        return try unsafe getter.unsafeInvoke()
    }

    func schema(action: NativeActionClass) async throws -> Data {
        let messaging = installation.framework("IDEIntelligenceMessaging", in: "PlugIns")
        _ = try await runtime.swiftType(named: "IDEIntelligenceMessaging.ToolSchema", in: .path(messaging))
        guard let schemaType = _typeByName("24IDEIntelligenceMessaging10ToolSchemaV") as? any Encodable.Type else {
            throw NativeRuntimeError.unsupportedContract("Native ToolSchema does not expose its Encodable contract")
        }
        if schemaEntry == nil {
            schemaEntry = try await runtime.resolve(.init(
                name: "static (extension in IDEIntelligenceMessaging):DVTFoundation.DVTStatelessAction.toolSchema.getter : IDEIntelligenceMessaging.ToolSchema", language: .swift
            ), in: .path(messaging))
        }
        guard let schemaEntry else { throw NativeRuntimeError.unavailable("Native schema getter is unavailable") }
        return try unsafe encodeSchema(schemaType, entry: schemaEntry, action: action)
    }

    private func encodeSchema<T: Encodable>(_ type: T.Type, entry: ResolvedSymbol, action: NativeActionClass) throws -> Data {
        if unsafe schemaInterface == nil {
            let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
            let output = try unsafe abi.indirectStorage(for: T.self)
            unsafe (schemaInterface = try abi.callInterface(result: output, parameters: [pointer, pointer]))
        }
        guard let interface = unsafe schemaInterface else { throw NativeRuntimeError.unavailable("Native schema call interface is unavailable") }
        var metadata = unsafe action.metadata
        var witness = unsafe action.conformance
        let value: T = try withUnsafeMutablePointer(to: &metadata) { metadata in
            try withUnsafeMutablePointer(to: &witness) { witness in
                try unsafe abi.invoke(symbol: entry, interface: interface,
                               arguments: [UnsafeMutableRawPointer(metadata), UnsafeMutableRawPointer(witness)],
                               context: action.metadata, returning: T.self)
            }
        }
        return try JSONEncoder().encode(value)
    }

    func execute(action: NativeActionClass, input: Data) async throws -> AsyncStream<Data> {
        if streamEntry == nil {
            streamEntry = try await runtime.resolve(.init(
                name: "static (extension in DVTFoundation):DVTFoundation.DVTStatelessAction.executeStream(inputJSON: Foundation.Data) -> Swift.AsyncStream<Foundation.Data>", language: .swift
            ), in: .path(installation.framework("DVTFoundation", in: "SharedFrameworks")))
            let word = try unsafe abi.scalar(Int32(ABIValueUInt64))
            let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
            let data = try unsafe abi.storage(for: Data.self, components: [word, word])
            let result = try unsafe abi.indirectStorage(for: AsyncStream<Data>.self)
            unsafe (streamInterface = try abi.callInterface(result: result, parameters: [data, pointer, pointer]))
        }
        guard let entry = streamEntry, let interface = unsafe streamInterface else {
            throw NativeRuntimeError.unavailable("Native action executor is unavailable")
        }
        try Task.checkCancellation()
        var input = input
        var metadata = unsafe action.metadata
        var witness = unsafe action.conformance
        return try withUnsafeMutablePointer(to: &input) { input in
            try withUnsafeMutablePointer(to: &metadata) { metadata in
                try withUnsafeMutablePointer(to: &witness) { witness in
                    try unsafe abi.invoke(symbol: entry, interface: interface,
                                   arguments: [UnsafeMutableRawPointer(input), UnsafeMutableRawPointer(metadata), UnsafeMutableRawPointer(witness)],
                                   context: action.metadata, returning: AsyncStream<Data>.self)
                }
            }
        }
    }
}
