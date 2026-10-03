import ABIBridge
import Foundation
import XcodeMCPWire

@MainActor
final class NativeWorkspaceRegistry {
    private let runtime = ABIRuntime.shared
    private let registry: AnyObject
    private var ownedIdentifiers = Set<String>()

    init(installation: NativeXcodeInstallation) async throws {
        let type = try await runtime.swiftType(named: "IDEFoundation.IDEWorkspaceRegistry", in: .path(installation.framework("IDEFoundation")), loading: .loadedOnly)
        let shared = try await type.staticGetter(named: "shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: AnyObject.self)
        registry = try unsafe shared.unsafeInvoke()
    }

    func resolve(_ selector: String) async throws -> String {
        if selector.hasPrefix("/") {
            let path = URL(fileURLWithPath: selector).standardizedFileURL.resolvingSymlinksInPath().path
            let open = try await runtime.object(registry).method(named: "open(path: Swift.String) async throws -> __C.IDEWorkspace", as: (@concurrent (String) async throws -> AnyObject).self)
            try Task.checkCancellation()
            let workspace = try unsafe await open.unsafeInvoke(path)
            let getter = try await runtime.object(workspace).getter(named: "workspaceIdentifier", as: String.self)
            let identifier = try unsafe getter.unsafeInvoke()
            ownedIdentifiers.insert(identifier)
            return identifier
        }
        return selector
    }

    func prepareDebugger(for identifier: String) async throws {
        let lookup = try await runtime.object(registry).method(named: "workspace(withIdentifier: Swift.String) -> Swift.Optional<__C.IDEWorkspace>", as: ((String) -> AnyObject?).self)
        try Task.checkCancellation()
        guard let workspace = try unsafe lookup.unsafeInvoke(identifier) else { return }
        let manager = try runtime.object(workspace).method(selector: "breakpointManager", as: (() -> AnyObject?).self)
        _ = try unsafe manager.unsafeInvoke()
    }

    func observe(toolName: String, arguments: [String: JSONValue], event: JSONValue) {
        guard case .object(let fields) = event, case .string("completed") = fields["type"],
              case .object(let data) = fields["data"] else { return }
        if toolName == "XcodeOpenWorkspace", case .string(let identifier) = data["workspaceIdentifier"] {
            ownedIdentifiers.insert(identifier)
        } else if toolName == "XcodeCloseWorkspace", case .string(let identifier) = arguments["workspaceIdentifier"] {
            ownedIdentifiers.remove(identifier)
        }
    }

    func closeOwnedWorkspaces() async throws {
        let close = try await runtime.object(registry).method(named: "close(identifier: Swift.String) throws -> ()", as: ((String) throws -> Void).self)
        var failures: [String] = []
        for identifier in ownedIdentifiers.sorted() {
            do {
                try unsafe close.unsafeInvoke(identifier)
                ownedIdentifiers.remove(identifier)
            } catch {
                failures.append("\(identifier): \(error)")
            }
        }
        if !failures.isEmpty {
            throw NativeRuntimeError.invocation("Failed to close owned workspaces: " + failures.joined(separator: "; "))
        }
    }
}
