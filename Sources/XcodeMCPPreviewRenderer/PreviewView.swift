#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import ABIBridgeSwiftUI
import DeveloperToolsSupport
import SwiftUI

// A generic declaration preserves the native argument's formal indirect ABI.
@inline(never)
public func previewValue<T>(_ value: T) -> T { value }

@MainActor
func requireSupportedTraits(_ preview: Preview) throws {
    // Preview exposes no trait-list getter. Enumerate its reflected values so
    // modifiers and future traits are delegated before invoking the body.
    guard let field = Mirror(reflecting: preview).children.first(where: { $0.label == "traits" }),
          let traits = field.value as? [Any] else {
        throw PreviewRendererError("The installed preview trait list has an unsupported representation")
    }
    guard traits.allSatisfy({ String(reflecting: type(of: $0)) == "DeveloperToolsSupport.PreviewLayoutTrait" }) else {
        throw NativePreviewPipelineRequired()
    }
}

@MainActor
func ownedPreview(_ preview: Preview) async throws -> NativeSwiftValue {
    let identity = try await ABIRuntime.shared.resolveSwiftFunction(
        named: "XcodeMCPPreviewRenderer.previewValue<A>(A) -> A",
        as: ((Preview) -> NativeSwiftValue).self, genericArguments: [.type(Preview.self)])
    return try unsafe identity.unsafeInvoke(preview)
}

@MainActor
func previewSource(_ preview: NativeSwiftValue) async throws -> NativeSwiftValue {
    let dataSource = try await ABIRuntime.shared.resolveSwiftType(
        named: "DeveloperToolsSupport.Preview.DataSource", in: .framework(named: "DeveloperToolsSupport"))
    let getter = try await preview.type.resolveGetter(named: "dataSource", as: (() -> NativeSwiftValue).self,
        valueABIs: [dataSource: .opaque(named: dataSource.name)], receiverABI: .opaque(named: preview.type.name))
    let value = try unsafe getter.unsafeInvoke(on: preview)
    guard let source = try await value.resolveEnumPayload(forCase: "preview") else {
        throw NativePreviewPipelineRequired()
    }
    return try source.copyUnderlyingValue()
}

@MainActor
func makeViewPreview(source: NativeSwiftValue) async throws -> AnyView {
    let runtime = ABIRuntime.shared
    let bodyType = try await runtime.resolveSwiftType(named: "SwiftUI.ViewPreviewBody", in: .framework(named: "SwiftUI"))
    let structureType = try await runtime.resolveSwiftType(
        named: "DeveloperToolsSupport.DefaultPreviewSource.Structure", in: .framework(named: "DeveloperToolsSupport"),
        genericArguments: [.type(bodyType)])
    let structureGetter = try await source.type.resolveGetter(named: "structure", as: (() -> NativeSwiftValue).self,
        valueABIs: [structureType: .opaque(named: structureType.name)], receiverABI: .opaque(named: source.type.name))
    let structure = try unsafe structureGetter.unsafeInvoke(on: source)
    guard let payload = try await structure.resolveEnumPayload(forCase: "singlePreview") else {
        throw NativePreviewPipelineRequired()
    }
    let function = try payload.copyTupleElement(at: 0)
    let closure = try await function.resolveClosure(as: (@MainActor () -> NativeSwiftValue).self)
    let body = try unsafe closure.unsafeInvoke()
    let getter = try await body.type.resolveGetter(named: "body", as: (() -> NativeSwiftValue).self,
        receiverABI: .opaque(named: body.type.name))
    let existential = try unsafe getter.unsafeInvoke(on: body)
    return try AnyView(NativeSwiftView(existential.copyUnderlyingValue()))
}

@MainActor
func viewPreviewLayout(_ preview: NativeSwiftValue) async throws -> DeveloperToolsSupport.PreviewLayout {
    guard let metatype = _typeByName("21DeveloperToolsSupport18PreviewLayoutTraitV") else {
        throw PreviewRendererError("The installed preview layout trait is unavailable")
    }
    func read<T>(_ trait: T.Type) async throws -> DeveloperToolsSupport.PreviewLayout {
        let value = try await preview.type.resolveMethod(
            named: "value<A where A: DeveloperToolsSupport.PreviewTraitProtocol>(for: A.Type) -> A.Value",
            as: ((T.Type) -> NativeSwiftValue).self, genericArguments: [.type(T.self)],
            receiverABI: .opaque(named: preview.type.name))
        let layout = try unsafe value.unsafeInvoke(on: preview, trait)
        return try layout.withCopy {
            guard let value = $0 as? DeveloperToolsSupport.PreviewLayout else {
                throw PreviewRendererError("The installed preview layout has an unsupported type")
            }
            return value
        }
    }
    return try await _openExistential(metatype, do: read)
}

struct PreviewRendererError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct NativePreviewPipelineRequired: Error {}
#endif
