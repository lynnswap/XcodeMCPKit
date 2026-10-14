#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS) || os(watchOS)
import ABIBridge
import ABIBridgeSwiftUI
import DeveloperToolsSupport
import SwiftUI
#if os(macOS)
import AppKit
#elseif !os(watchOS)
import UIKit
#endif

// A generic declaration preserves the native argument's formal indirect ABI.
@inline(never)
public func previewValue<T>(_ value: T) -> T { value }

@MainActor
func requireSupportedTraits(_ preview: Preview) throws {
    // Preview exposes no trait-list getter. Inspect the stored list before
    // creating a body whose traits require the native pipeline.
    guard let field = Mirror(reflecting: preview).children.first(where: { $0.label == "traits" }),
          let traits = field.value as? [Any] else {
        throw PreviewRendererError("The installed preview trait list has an unsupported representation")
    }
    guard traits.allSatisfy({ trait in
        let name = String(reflecting: type(of: trait))
        return name == "DeveloperToolsSupport.PreviewLayoutTrait"
            || name == "DeveloperToolsSupport.PreviewInterfaceOrientationTrait"
            || name == "SwiftUI.PreviewModifierTrait"
    }) else {
        throw NativePreviewPipelineRequired()
    }
}

@MainActor
func ownedPreview(_ preview: Preview) async throws -> NativeSwiftValue {
    try await ownedPreviewValue(preview)
}

@MainActor
func ownedPreviewValue<Value>(_ value: Value) async throws -> NativeSwiftValue {
    let identity = try await ABIRuntime.shared.resolveSwiftFunction(
        named: "XcodeMCPPreviewRenderer.previewValue<A>(A) -> A",
        as: ((Value) -> NativeSwiftValue).self, genericArguments: [.type(Value.self)])
    return try unsafe identity.unsafeInvoke(value)
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
struct ViewPreview {
    let view: AnyView
    let groupItems: [String?]?
    let errors: [String]
}

@MainActor
func makeViewPreview(source: NativeSwiftValue, groupItemIndex: Int? = nil) async throws -> ViewPreview {
    let runtime = ABIRuntime.shared
    let bodyArgument: NativeSwiftGenericArgument
    let makeView: @MainActor (NativeSwiftValue) async throws -> AnyView
    switch source.type.name {
    case "DeveloperToolsSupport.DefaultPreviewSource<SwiftUI.ViewPreviewBody>":
        let bodyType = try await runtime.resolveSwiftType(named: "SwiftUI.ViewPreviewBody", in: .framework(named: "SwiftUI"))
        bodyArgument = .type(bodyType)
        makeView = { body in
            let getter = try await body.type.resolveGetter(named: "body", as: (() -> NativeSwiftValue).self,
                receiverABI: .opaque(named: body.type.name))
            let existential = try unsafe getter.unsafeInvoke(on: body)
            return try AnyView(NativeSwiftView(existential.copyUnderlyingValue()))
        }
    #if !os(macOS) && !os(watchOS)
    case "DeveloperToolsSupport.DefaultPreviewSource<__C.UIView>":
        bodyArgument = .type(UIView.self)
        makeView = { body in
            guard let view = try body.withCopy({ $0 as? UIView }) else {
                throw PreviewRendererError("The installed preview body is not a UIView")
            }
            return AnyView(PreviewUIView(view: view))
        }
    case "DeveloperToolsSupport.DefaultPreviewSource<__C.UIViewController>":
        bodyArgument = .type(UIViewController.self)
        makeView = { body in
            guard let controller = try body.withCopy({ $0 as? UIViewController }) else {
                throw PreviewRendererError("The installed preview body is not a UIViewController")
            }
            return AnyView(PreviewUIViewController(controller: controller))
        }
    #elseif os(macOS)
    case "DeveloperToolsSupport.DefaultPreviewSource<__C.NSView>":
        bodyArgument = .type(NSView.self)
        makeView = { body in
            guard let view = try body.withCopy({ $0 as? NSView }) else { throw PreviewRendererError("The installed preview body is not an NSView") }
            return AnyView(PreviewNSView(view: view).ignoresSafeArea(.all, edges: .all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor)))
        }
    case "DeveloperToolsSupport.DefaultPreviewSource<__C.NSViewController>":
        bodyArgument = .type(NSViewController.self)
        makeView = { body in
            guard let controller = try body.withCopy({ $0 as? NSViewController }) else { throw PreviewRendererError("The installed preview body is not an NSViewController") }
            return AnyView(PreviewNSViewController(controller: controller).ignoresSafeArea(.all, edges: .all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor)))
        }
    #endif
    default: throw NativePreviewPipelineRequired()
    }
    let result = try await previewBody(source: source, bodyArgument: bodyArgument, groupItemIndex: groupItemIndex)
    return ViewPreview(view: try await makeView(result.body), groupItems: result.groupItems, errors: result.errors)
}

@MainActor
private func previewBody(source: NativeSwiftValue, bodyArgument: NativeSwiftGenericArgument,
                         groupItemIndex: Int?) async throws -> (body: NativeSwiftValue, groupItems: [String?]?, errors: [String]) {
    let runtime = ABIRuntime.shared
    let structureType = try await runtime.resolveSwiftType(
        named: "DeveloperToolsSupport.DefaultPreviewSource.Structure", in: .framework(named: "DeveloperToolsSupport"),
        genericArguments: [bodyArgument])
    let structureGetter = try await source.type.resolveGetter(named: "structure", as: (() -> NativeSwiftValue).self,
        valueABIs: [structureType: .opaque(named: structureType.name)], receiverABI: .opaque(named: source.type.name))
    let structure = try unsafe structureGetter.unsafeInvoke(on: source)
    if let payload = try await structure.resolveEnumPayload(forCase: "singlePreview") {
        let function = try payload.copyTupleElement(at: 0)
        let closure = try await function.resolveClosure(as: (@MainActor () -> NativeSwiftValue).self)
        let errors = groupItemIndex.map { [unsupportedPreviewGroupItemMessage($0, supportsGroups: false)] } ?? []
        return (try unsafe closure.unsafeInvoke(), nil, errors)
    }
    let indexType = try await runtime.resolveSwiftType(named: "DeveloperToolsSupport.PreviewGroupIndex",
        in: .framework(named: "DeveloperToolsSupport"))
    let optionalIndexType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(indexType)])
    // These resilient closed values use indirect parameters and results. The
    // body's generic argument keeps its declaration's formal ABI.
    guard let payload = try await structure.resolveEnumPayload(forCase: "previewGroup",
        valueABIs: [indexType: .opaque(named: indexType.name), optionalIndexType: .opaque(named: optionalIndexType.name)]) else {
        throw NativePreviewPipelineRequired()
    }
    let items = try await previewGroupItems(payload.copyTupleElement(at: 0))
    let requestedIndex: NativeSwiftValue
    var errors: [String] = []
    if let groupItemIndex, items.indices.contains(groupItemIndex) {
        let item = items[groupItemIndex]
        let initializer = try await indexType.resolveInitializer(
            named: "init(section: Swift.Int, preview: Swift.Int) -> DeveloperToolsSupport.PreviewGroupIndex",
            as: ((Int, Int) -> NativeSwiftValue).self, valueABIs: [indexType: .opaque(named: indexType.name)])
        requestedIndex = try await optionalPreviewIndex(unsafe initializer.unsafeInvoke(item.section, item.preview))
    } else {
        if let groupItemIndex { errors.append(unsupportedPreviewGroupItemMessage(groupItemIndex, supportsGroups: true)) }
        guard let metadata = _typeByName("21DeveloperToolsSupport17PreviewGroupIndexV") else {
            throw PreviewRendererError("The installed preview group index is unavailable")
        }
        @MainActor func none<Value>(_ type: Value.Type) async throws -> NativeSwiftValue {
            try await ownedPreviewValue(Optional<Value>.none)
        }
        requestedIndex = try await _openExistential(metadata, do: none)
    }
    let function = try payload.copyTupleElement(at: 1)
    let closure = try await function.resolveClosure(as: (@MainActor (NativeSwiftValue) -> NativeSwiftValue).self)
    let result = try unsafe closure.unsafeInvoke(requestedIndex)
    return (try result.copyTupleElement(at: 0), items.map(\.description), errors)
}

func unsupportedPreviewGroupItemMessage(_ index: Int, supportsGroups: Bool) -> String {
    let detail = supportsGroups
        ? "see the `supportedCanvasControlOverrides` field of the result for the list of supported group items indexes for rendering this preview in the currently active scheme."
        : "the specified preview doesn't support group items in the currently active scheme."
    return "Unsupported group item index \(index); \(detail)"
}

@MainActor
private func optionalPreviewIndex(_ index: NativeSwiftValue) async throws -> NativeSwiftValue {
    let value = try index.withCopy { $0 }
    @MainActor func some<Value>(_ value: Value) async throws -> NativeSwiftValue {
        try await ownedPreviewValue(Optional.some(value))
    }
    return try await _openExistential(value, do: some)
}

@MainActor
private func previewGroupItems(_ metadata: NativeSwiftValue) async throws -> [(section: Int, preview: Int, description: String?)] {
    let sectionType = try await ABIRuntime.shared.resolveSwiftType(named: "DeveloperToolsSupport.PreviewGroupMetadata.Section",
        in: .framework(named: "DeveloperToolsSupport"))
    let firstGetter = try await metadata.type.resolveGetter(named: "firstSection", as: (() -> NativeSwiftValue).self,
        valueABIs: [sectionType: .opaque(named: sectionType.name)], receiverABI: .opaque(named: metadata.type.name))
    var sections = [try unsafe firstGetter.unsafeInvoke(on: metadata)]
    let moreGetter = try await metadata.type.resolveGetter(named: "moreSections", as: (() -> NativeSwiftValue).self,
        receiverABI: .opaque(named: metadata.type.name))
    let more = try unsafe moreGetter.unsafeInvoke(on: metadata)
    let values = try more.withCopy { value -> [Any] in
        guard let collection = value as? any Collection else {
            throw PreviewRendererError("The installed preview group sections have an unsupported type")
        }
        return collection.map { $0 }
    }
    for value in values {
        @MainActor func own<Value>(_ value: Value) async throws -> NativeSwiftValue { try await ownedPreviewValue(value) }
        sections.append(try await _openExistential(value, do: own))
    }
    var items: [(section: Int, preview: Int, description: String?)] = []
    for (sectionIndex, section) in sections.enumerated() {
        let countGetter = try await section.type.resolveGetter(named: "previewCount", as: (() -> Int).self,
            receiverABI: .opaque(named: section.type.name))
        let count = try unsafe countGetter.unsafeInvoke(on: section)
        let descriptions: [String?]
        do {
            let getter = try await section.type.resolveGetter(named: "itemDescriptions", as: (() -> [String?]).self,
                receiverABI: .opaque(named: section.type.name))
            descriptions = try unsafe getter.unsafeInvoke(on: section)
        } catch ABIResolutionError.declarationNotFound {
            // Earlier runtimes provide the count but no per-item descriptions.
            descriptions = []
        }
        for previewIndex in 0..<count {
            items.append((sectionIndex, previewIndex, descriptions.indices.contains(previewIndex) ? descriptions[previewIndex] : nil))
        }
    }
    return items
}

@MainActor
func applyPreviewModifiers(_ view: AnyView, preview: NativeSwiftValue) async throws -> AnyView {
    guard let metadata = _typeByName("7SwiftUI20PreviewModifierTraitV") else {
        throw PreviewRendererError("The installed preview modifier trait is unavailable")
    }
    @MainActor func read<T>(_ trait: T.Type) async throws -> [any PreviewModifier] {
        let getter = try await preview.type.resolveMethod(
            named: "value<A where A: DeveloperToolsSupport.PreviewTraitProtocol>(for: A.Type) -> A.Value",
            as: ((T.Type) -> NativeSwiftValue).self, genericArguments: [.type(T.self)], receiverABI: .opaque(named: preview.type.name))
        let value = try unsafe getter.unsafeInvoke(on: preview, trait)
        return try value.withCopy {
            guard let modifiers = $0 as? [any PreviewModifier] else {
                throw PreviewRendererError("The installed preview modifiers have an unsupported type")
            }
            return modifiers
        }
    }
    let modifiers = try await _openExistential(metadata, do: read)
    var contexts: [ObjectIdentifier: Any] = [:]
    var content = view
    for modifier in modifiers {
        @MainActor func apply<M: PreviewModifier>(_ modifier: M) async throws -> AnyView {
            let key = ObjectIdentifier(M.self)
            let context: M.Context
            if let cached = contexts[key] as? M.Context {
                context = cached
            } else {
                context = try await M.makeSharedContext()
                contexts[key] = context
            }
            let wrapperType = try await ABIRuntime.shared.resolveSwiftType(named: "SwiftUI.PreviewModifierViewModifier",
                in: .framework(named: "SwiftUI"), genericArguments: [.type(M.self)])
            let initializer = try await wrapperType.resolveInitializer(
                named: "init(modifier: A, context: A.Context) -> SwiftUI.PreviewModifierViewModifier<A>",
                as: ((M, M.Context) -> NativeSwiftValue).self, valueABIs: [wrapperType: .opaque(named: wrapperType.name)])
            let wrapper = try unsafe initializer.unsafeInvoke(modifier, context)
            guard let viewModifier = try wrapper.withCopy({ $0 as? any ViewModifier }) else {
                throw PreviewRendererError("The installed preview modifier wrapper does not conform to ViewModifier")
            }
            @MainActor func use<V: ViewModifier>(_ value: V) -> AnyView { AnyView(content.modifier(value)) }
            return _openExistential(viewModifier, do: use)
        }
        content = try await _openExistential(modifier, do: apply)
    }
    return content
}

@MainActor
func makeLegacyViewPreview(typeName: String, index: Int) throws -> SwiftUI._Preview {
    guard let provider = _typeByName(typeName) as? any SwiftUI._PreviewProvider.Type else {
        throw NativePreviewPipelineRequired()
    }
    let previews = provider._allPreviews
    guard previews.indices.contains(index) else { throw NativePreviewPipelineRequired() }
    return previews[index]
}

#if !os(macOS) && !os(watchOS)
private struct PreviewUIView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct PreviewUIViewController: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

#elseif os(macOS)
private struct PreviewNSView: NSViewControllerRepresentable {
    let view: NSView
    func makeNSViewController(context: Context) -> NSViewController {
        let container = NSViewController()
        containPreviewView(view, in: container.view)
        return container
    }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

private struct PreviewNSViewController: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController {
        let container = NSViewController()
        container.addChild(controller)
        containPreviewView(controller.view, in: container.view)
        return container
    }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

// Containment preserves the AppKit body's control styling instead of letting
// SwiftUI's representable adapter restyle a leaf control.
@MainActor
private func containPreviewView(_ content: NSView, in container: NSView) {
    container.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    let edges = [
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        content.topAnchor.constraint(equalTo: container.topAnchor),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ]
    // Weak edge equalities preserve intrinsic control sizes while allowing
    // content without an intrinsic size to use SwiftUI's available proposal.
    for constraint in edges { constraint.priority = NSLayoutConstraint.Priority(1) }
    NSLayoutConstraint.activate(edges + [
        content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
        content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        content.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
        content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
}
#endif

@MainActor
func viewPreviewLayout(_ preview: NativeSwiftValue) async throws -> DeveloperToolsSupport.PreviewLayout {
    let layout = try await previewTraitValue(preview, named: "21DeveloperToolsSupport18PreviewLayoutTraitV")
    return try layout.withCopy {
        guard let value = $0 as? DeveloperToolsSupport.PreviewLayout else {
            throw PreviewRendererError("The installed preview layout has an unsupported type")
        }
        return value
    }
}

@MainActor
func previewTraitValue(_ preview: NativeSwiftValue, named mangledName: String) async throws -> NativeSwiftValue {
    guard let metatype = _typeByName(mangledName) else { throw NativePreviewPipelineRequired() }
    func read<T>(_ trait: T.Type) async throws -> NativeSwiftValue {
        let value = try await preview.type.resolveMethod(
            named: "value<A where A: DeveloperToolsSupport.PreviewTraitProtocol>(for: A.Type) -> A.Value",
            as: ((T.Type) -> NativeSwiftValue).self, genericArguments: [.type(T.self)],
            receiverABI: .opaque(named: preview.type.name))
        return try unsafe value.unsafeInvoke(on: preview, trait)
    }
    return try await _openExistential(metatype, do: read)
}

struct PreviewRendererError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct NativePreviewPipelineRequired: Error {}
#endif
