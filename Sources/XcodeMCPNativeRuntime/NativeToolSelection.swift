import ABIBridge
import ABIBridgeCore
import Foundation

@safe
@MainActor
final class NativeToolSelection {
    private let runtime = ABIRuntime.shared
    private let abi = NativeABI()
    private let settings: AnyObject
    private let metadata: UnsafeRawPointer
    private let witness: UnsafeRawPointer
    private let headlessGetter: ResolvedSymbol
    private let asynchronous: Bool
    private let interface: OpaquePointer

    init(installation: NativeXcodeInstallation) async throws {
        let image = installation.framework("IDEIntelligenceChat", in: "PlugIns")
        let type = try await runtime.resolve(.swift(.type("IDEIntelligenceChat.AppStorageChatSettings")), in: .path(image))
        let shared = try await type.resolve(.swift(.staticGetter("shared.getter : IDEIntelligenceChat.AppStorageChatSettings", as: (() -> AnyObject).self)))
        settings = try unsafe shared.unsafeInvoke()
        unsafe (metadata = unsafeBitCast(Swift.type(of: settings), to: UnsafeRawPointer.self))
        let protocolSymbol = try await runtime.resolve(
            .swift(.symbol("protocol descriptor for IDEIntelligenceChat.ChatSettings", kind: .data)), in: .path(image))
        let conforms = try unsafe await runtime.resolve(
            .c(.function("swift_conformsToProtocol", as: ((UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?).self)))
        let settingsMetadata = unsafe metadata
        guard let conformance = try unsafe protocolSymbol.withUnsafeAddress({ try unsafe conforms.unsafeInvoke(settingsMetadata, $0) }) else {
            throw NativeRuntimeError.unsupportedContract("Native chat settings do not conform to ChatSettings")
        }
        unsafe (witness = conformance)
        let declaration = "(extension in IDEIntelligenceChat):IDEIntelligenceChat.ChatSettings.enabledHeadlessMCPTools.getter : Swift.Set<Swift.String>"
        // Xcode 27.2 made this getter synchronous; earlier versions export an async descriptor.
        do {
            headlessGetter = try await runtime.resolve(
                .swift(.symbol("async function pointer to " + declaration, kind: .data)), in: .path(image))
            asynchronous = true
        } catch ABIResolutionError.declarationNotFound {
            headlessGetter = try await runtime.resolve(.swift(.symbol(declaration, kind: .function)), in: .path(image))
            asynchronous = false
        }
        let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
        let result = try unsafe abi.storage(for: Set<String>.self, components: [pointer])
        unsafe (interface = try asynchronous
            ? abi.asyncInterface(result: result, parameters: [pointer, pointer])
            : abi.callInterface(result: result, parameters: [pointer, pointer]))
    }

    func publicToolNames() async throws -> Set<String> {
        try await read(headlessGetter)
    }

    private func read(_ getter: ResolvedSymbol) async throws -> Set<String> {
        let inputs = UnsafeMutablePointer<UnsafeRawPointer>.allocate(capacity: 2)
        unsafe inputs.initialize(to: metadata)
        unsafe (inputs + 1).initialize(to: witness)
        defer { unsafe inputs.deinitialize(count: 2); unsafe inputs.deallocate() }
        // A generic Self parameter refers to storage for the class reference,
        // rather than using the concrete object address as its Swift self.
        let genericSelf = UnsafeMutablePointer<UnsafeRawPointer>.allocate(capacity: 1)
        unsafe genericSelf.initialize(to: UnsafeRawPointer(Unmanaged.passUnretained(settings).toOpaque()))
        defer { unsafe genericSelf.deinitialize(count: 1); unsafe genericSelf.deallocate() }
        defer { withExtendedLifetime(settings) {} }
        if !asynchronous {
            return try unsafe abi.invoke(symbol: getter, interface: interface,
                                         arguments: [UnsafeMutableRawPointer(inputs), UnsafeMutableRawPointer(inputs + 1)],
                                         context: UnsafeRawPointer(genericSelf), returning: Set<String>.self)
        }
        return try unsafe await abi.invokeAsync(symbol: getter, interface: interface,
                                         arguments: [UnsafeMutableRawPointer(inputs), UnsafeMutableRawPointer(inputs + 1)],
                                         context: UnsafeRawPointer(genericSelf), returning: Set<String>.self)
    }
}
