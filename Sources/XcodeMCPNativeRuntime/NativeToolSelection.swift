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
    private let guiGetter: ResolvedSymbol
    private let interface: OpaquePointer

    init(installation: NativeXcodeInstallation) async throws {
        let image = installation.framework("IDEIntelligenceChat", in: "PlugIns")
        let type = try await runtime.swiftType(named: "IDEIntelligenceChat.AppStorageChatSettings", in: .path(image))
        let shared = try await type.staticGetter(named: "shared.getter : IDEIntelligenceChat.AppStorageChatSettings", as: (() -> AnyObject).self)
        settings = try unsafe shared.unsafeInvoke()
        unsafe (metadata = unsafeBitCast(Swift.type(of: settings), to: UnsafeRawPointer.self))
        let protocolSymbol = try await runtime.resolve(.init(name: "protocol descriptor for IDEIntelligenceChat.ChatSettings", language: .swift, kind: .data), in: .path(image))
        let conforms = try unsafe await runtime.cFunction(named: "swift_conformsToProtocol", as: ((UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?).self)
        let settingsMetadata = unsafe metadata
        guard let conformance = try unsafe protocolSymbol.withUnsafeAddress({ try unsafe conforms.unsafeInvoke(settingsMetadata, $0) }) else {
            throw NativeRuntimeError.unsupportedContract("Native chat settings do not conform to ChatSettings")
        }
        unsafe (witness = conformance)
        headlessGetter = try await runtime.resolve(.init(name: "async function pointer to (extension in IDEIntelligenceChat):IDEIntelligenceChat.ChatSettings.enabledHeadlessMCPTools.getter : Swift.Set<Swift.String>", language: .swift, kind: .data), in: .path(image))
        guiGetter = try await runtime.resolve(.init(name: "async function pointer to (extension in IDEIntelligenceChat):IDEIntelligenceChat.ChatSettings.enabledMCPTools.getter : Swift.Set<Swift.String>", language: .swift, kind: .data), in: .path(image))
        let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
        let result = try unsafe abi.storage(for: Set<String>.self, components: [pointer])
        unsafe (interface = try abi.asyncInterface(result: result, parameters: [pointer, pointer]))
    }

    func publicToolNames() async throws -> Set<String> {
        let headless = try await read(headlessGetter)
        let gui = try await read(guiGetter)
        return headless.union(gui)
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
        return try unsafe await abi.invokeAsync(symbol: getter, interface: interface,
                                         arguments: [UnsafeMutableRawPointer(inputs), UnsafeMutableRawPointer(inputs + 1)],
                                         context: UnsafeRawPointer(genericSelf), returning: Set<String>.self)
    }
}
