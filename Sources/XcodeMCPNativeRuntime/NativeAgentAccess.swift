import ABIBridge
import CryptoKit
import Foundation
import XcodeMCPWire

@MainActor
package final class NativeAgentAccess {
    private let store: AnyObject
    private let storeType: NativeSwiftType
    private let stateType: NativeSwiftType
    private let stateMetadata: any Codable.Type

    package init(installation: NativeXcodeInstallation) async throws {
        let runtime = ABIRuntime.shared
        let image = installation.framework("IDEIntelligenceFoundation", in: "PlugIns")
        storeType = try await runtime.swiftType(named: "IDEIntelligenceFoundation.DefaultHeadlessPermissionStore", in: .path(image))
        stateType = try await runtime.swiftType(named: "IDEIntelligenceFoundation.HeadlessPermissionState", in: .path(image))
        let shared = try await storeType.staticGetter(
            named: "shared.getter : IDEIntelligenceFoundation.DefaultHeadlessPermissionStore", as: (() -> AnyObject).self)
        store = try unsafe shared.unsafeInvoke()
        guard let metadata = try await NativeABI().typeMetadata(named: stateType.name, in: image) as? any Codable.Type else {
            throw NativeRuntimeError.unsupportedContract("Xcode's permission state does not support Codable")
        }
        stateMetadata = metadata
    }

    package init(store: AnyObject, storeType: NativeSwiftType, stateType: NativeSwiftType,
                 stateMetadata: any Codable.Type) {
        self.store = store
        self.storeType = storeType
        self.stateType = stateType
        self.stateMetadata = stateMetadata
    }

    package func authorize(executable: URL, identity: NativeSigningIdentity?) async throws {
        try await update(NativeAgentGrant(executable: executable, identity: identity))
    }

    package func snapshot() async throws -> [String: JSONValue] {
        let snapshot = try await storeType.method(
            named: "snapshot() -> \(stateType.name)", as: (() -> NativeSwiftValue).self,
            valueABIs: [stateType: .opaque(named: stateType.name)])
        let value = try unsafe snapshot.unsafeInvoke(on: store)
        return try value.withCopy { copy in
            guard let encodable = copy as? any Encodable else {
                throw NativeRuntimeError.unsupportedContract("Xcode's permission snapshot is not Encodable")
            }
            return try NativeAgentGrant.decode(JSONEncoder().encode(encodable))
        }
    }

    package func update(_ grant: NativeAgentGrant) async throws {
        try await edit(stateMetadata, grant: grant)
    }

    private func edit<State: Codable>(_ metadata: State.Type, grant: NativeAgentGrant) async throws {
        typealias Edit = NativeSwiftClosure<(NativeSwiftInout<NativePermissionStateValue<State>>) throws -> Void>
        let body = try Edit { slot in
            var state = try NativeAgentGrant.decode(JSONEncoder().encode(slot.value.value))
            try grant.apply(to: &state)
            let data = try JSONSerialization.data(withJSONObject: state.mapValues(\.foundationObject))
            slot.value = NativePermissionStateValue(value: try JSONDecoder().decode(State.self, from: data))
        }
        // Xcode owns the file lock, persistence, and Keychain integrity hash.
        // The native Codable value retains unrelated agent and folder records.
        let withState = try await storeType.method(
            named: "withState<A>((inout \(stateType.name)) throws -> A) throws -> A",
            as: ((Edit) throws -> Void).self, genericArguments: [.type(Void.self)],
            valueABIs: [stateType: .opaque(named: stateType.name)])
        try unsafe withState.unsafeInvoke(on: store, body)
    }
}

// A single-field wrapper preserves the native state's compiler-managed value
// while declaring its indirect ABI to the generic inout callback adapter.
private struct NativePermissionStateValue<State: Codable>: ABIBridgeSwiftValue {
    var value: State
    static var swiftABIType: NativeType { try! .opaque(named: String(reflecting: State.self)) }
}

package struct NativeAgentGrant: Sendable {
    package enum Identity: Sendable {
        case signed(NativeSigningIdentity)
        case unsigned(path: String, sha256: String, expiration: Date)
    }

    package let identity: Identity

    package init(identity: Identity) { self.identity = identity }

    package init(executable: URL, identity: NativeSigningIdentity?, now: Date = Date()) throws {
        if let identity {
            self.identity = .signed(identity)
        } else {
            let data = try Data(contentsOf: executable, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            self.identity = .unsigned(path: executable.path, sha256: digest,
                                      expiration: now.addingTimeInterval(24 * 60 * 60))
        }
    }

    package static func decode(_ data: Data) throws -> [String: JSONValue] {
        guard let value = JSONValue(any: try JSONSerialization.jsonObject(with: data)), case .object(let state) = value else {
            throw NativeRuntimeError.unsupportedContract("Xcode's permission state is not an object")
        }
        return state
    }

    package func apply(to state: inout [String: JSONValue]) throws {
        guard case .array(var records) = state["agentPermissions"] else {
            throw NativeRuntimeError.unsupportedContract("Xcode's permission state has no agent permission list")
        }
        if let index = records.firstIndex(where: matches), case .object(var record) = records[index] {
            record["trust"] = trust
            records[index] = .object(record)
        } else {
            records.append(.object(["id": .string(UUID().uuidString), "trust": trust]))
        }
        state["agentPermissions"] = .array(records)
        state["enabled"] = .bool(true)
        state["alwaysAllowAgents"] = .bool(true)
    }

    private var trust: JSONValue {
        switch identity {
        case .signed(let identity):
            return .object(["signed": identity.json])
        case .unsigned(let path, let hash, let expiration):
            return .object(["unsigned": .object([
                "path": .string(path), "sha256": .string(hash),
                "expiration": .number(.double(expiration.timeIntervalSinceReferenceDate)),
            ])])
        }
    }

    private func matches(_ record: JSONValue) -> Bool {
        guard case .object(let fields) = record, case .object(let trust) = fields["trust"] else { return false }
        switch identity {
        case .signed(let identity):
            guard case .object(let signed) = trust["signed"] else { return false }
            return signed["teamIdentifier"] == .string(identity.teamIdentifier)
                && signed["signingIdentifier"] == .string(identity.signingIdentifier)
        case .unsigned(let path, _, _):
            guard case .object(let unsigned) = trust["unsigned"] else { return false }
            return unsigned["path"] == .string(path)
        }
    }
}
