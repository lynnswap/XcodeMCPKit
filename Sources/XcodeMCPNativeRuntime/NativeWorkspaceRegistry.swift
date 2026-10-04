import ABIBridge
import Foundation

@MainActor
final class NativeWorkspaceRegistry {
    private let runtime = ABIRuntime.shared
    private let registry: AnyObject

    init(installation: NativeXcodeInstallation) async throws {
        let type = try await runtime.swiftType(named: "IDEFoundation.IDEWorkspaceRegistry", in: .path(installation.framework("IDEFoundation")), loading: .loadedOnly)
        let shared = try await type.staticGetter(named: "shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: (() -> AnyObject).self)
        registry = try unsafe shared.unsafeInvoke()
    }

    func resolve(_ selector: String, opensIfMissing: Bool = true) async throws -> String {
        if selector.hasPrefix("/") {
            let path = URL(fileURLWithPath: selector).standardizedFileURL.resolvingSymlinksInPath().path
            let matches = try await entries().filter { entry in
                entry.path.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } == path
            }
            if let match = matches.first {
                guard matches.count == 1 else {
                    throw NativeRuntimeError.invalidRequest("Multiple native workspaces match '\(selector)'; select a workspaceIdentifier: " + matches.map(\.identifier).sorted().joined(separator: ", "))
                }
                return match.identifier
            }
            guard opensIfMissing else {
                throw NativeRuntimeError.invalidRequest("No open native workspace matches '\(selector)'")
            }
            let open = try await runtime.object(registry).method(named: "open(path: Swift.String) async throws -> __C.IDEWorkspace", as: (@concurrent (String) async throws -> AnyObject).self)
            try Task.checkCancellation()
            let workspace: AnyObject
            do {
                workspace = try unsafe await open.unsafeInvoke(path)
            } catch let error as NativeSwiftError {
                if error.withUnderlyingError({ $0 is CancellationError }) { throw CancellationError() }
                throw NativeToolExecutionError(message: error.description)
            }
            let getter = try await runtime.object(workspace).getter(named: "workspaceIdentifier", as: (() -> String).self)
            let identifier = try unsafe getter.unsafeInvoke()
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

    // This registry belongs to the headless host process. Its native snapshot
    // also includes opens whose completion event a cancelled caller did not see.
    func closeAllWorkspaces() async throws {
        let identifiers = Set(try await entries().map(\.identifier))
        let close = try await runtime.object(registry).method(named: "close(identifier: Swift.String) throws -> ()", as: ((String) throws -> Void).self)
        var failures: [String] = []
        for identifier in identifiers.sorted() {
            do {
                try unsafe close.unsafeInvoke(identifier)
            } catch {
                failures.append("\(identifier): \(error)")
            }
        }
        if !failures.isEmpty {
            throw NativeRuntimeError.invocation("Failed to close native workspaces: " + failures.joined(separator: "; "))
        }
    }

    private func entries() async throws -> [(identifier: String, path: String?)] {
        let list = try await runtime.object(registry).method(
            named: "list() -> Swift.Array<IDEFoundation.IDEWorkspaceRegistry.WorkspaceInfo>",
            as: (() -> NativeSwiftValue).self)
        let snapshot = try unsafe list.unsafeInvoke()
        return try snapshot.withCopy { value in
            guard let values = value as? [Any] else {
                throw NativeRuntimeError.unsupportedContract("Native workspace registry did not return an array")
            }
            return try values.map { value in
                let fields = Mirror(reflecting: value).children
                guard let identifier = fields.first(where: { $0.label == "identifier" })?.value as? String,
                      let pathField = fields.first(where: { $0.label == "path" }),
                      let path = pathField.value as? String? else {
                    throw NativeRuntimeError.unsupportedContract("Native workspace registry entry has no identifier or optional path")
                }
                return (identifier, path)
            }
        }
    }
}
