import ABIBridge
import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativeAgentAccessTests {
    private let identity = NativeSigningIdentity(teamIdentifier: "OURTEAM", signingIdentifier: "example.helper")
    private let executable = URL(fileURLWithPath: "/tmp/Helper.app/Contents/MacOS/helper")

    @Test func automaticallyAllowsAllAgentsAndPreservesOtherSavedPermissions() throws {
        let other = record(team: "OTHERTEAM", identifier: identity.signingIdentifier)
        var state: [String: JSONValue] = [
            "enabled": .bool(false), "alwaysAllowAgents": .bool(false),
            "folderPermissions": .array([.string("existing-folder")]), "version": .number(.int(1)),
            "agentPermissions": .array([other]), "futureField": .object(["kept": .bool(true)]),
        ]
        let grant = NativeAgentGrant(identity: .signed(identity))
        try grant.apply(to: &state)
        let granted = state
        try grant.apply(to: &state)
        #expect(state == granted)
        #expect(state["enabled"] == .bool(true))
        #expect(state["alwaysAllowAgents"] == .bool(true))
        #expect(state["folderPermissions"] == .array([.string("existing-folder")]))
        #expect(state["futureField"] == .object(["kept": .bool(true)]))
        guard case .array(let records) = state["agentPermissions"] else { Issue.record("missing records"); return }
        #expect(records.count == 2)
        #expect(records[0] == other)
    }

    @Test func renewsAnExistingSignedGrantWithoutReplacingItsIdentifier() throws {
        var state: [String: JSONValue] = ["agentPermissions": .array([
            record(team: identity.teamIdentifier, identifier: identity.signingIdentifier, expiration: 10),
        ])]
        try NativeAgentGrant(identity: .signed(identity)).apply(to: &state)
        guard case .array(let records) = state["agentPermissions"] else { Issue.record("missing records"); return }
        #expect(records.count == 1)
        #expect(try nativeTestField(records[0], "id") == .string("existing-id"))
        guard case .object(let fields) = try nativeTestField(records[0], "trust", "signed") else { Issue.record("missing identity"); return }
        #expect(fields["expiration"] == nil)
    }

    @Test func unsignedBuildsRefreshTheirHashAndExpiryAtTheSamePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("helper")
        try Data("a".utf8).write(to: binary)
        var state: [String: JSONValue] = ["agentPermissions": .array([])]
        try NativeAgentGrant(executable: binary, identity: nil, now: Date(timeIntervalSinceReferenceDate: 100)).apply(to: &state)
        guard case .array(let before) = state["agentPermissions"] else { Issue.record("missing records"); return }
        #expect(try nativeTestField(before[0], "trust", "unsigned", "sha256") == .string("ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"))
        try Data("b".utf8).write(to: binary)
        try NativeAgentGrant(executable: binary, identity: nil, now: Date(timeIntervalSinceReferenceDate: 200)).apply(to: &state)
        guard case .array(let after) = state["agentPermissions"] else { Issue.record("missing records"); return }
        #expect(after.count == 1)
        #expect(try nativeTestField(after[0], "id") == nativeTestField(before[0], "id"))
        #expect(try nativeTestField(after[0], "trust", "unsigned", "sha256") != nativeTestField(before[0], "trust", "unsigned", "sha256"))
        #expect(try nativeTestField(after[0], "trust", "unsigned", "expiration") == .number(.double(86_600)))
    }

    @Test func editsTheNativeCodableStateInsideItsStoreTransaction() async throws {
        let fixture = NativePermissionStoreFixture()
        let runtime = ABIRuntime.shared
        let access = NativeAgentAccess(
            store: fixture,
            storeType: try await runtime.swiftType(named: "XcodeMCPNativeRuntimeTests.NativePermissionStoreFixture"),
            stateType: try await runtime.swiftType(named: "XcodeMCPNativeRuntimeTests.NativePermissionFixtureState"),
            stateMetadata: NativePermissionFixtureState.self)
        try await access.update(NativeAgentGrant(identity: .signed(identity)))
        #expect(fixture.transactions == 1)
        #expect(fixture.state.agentPermissions.count == 1)
        #expect(fixture.state.folderPermissions == ["existing-folder"])
        #expect(fixture.state.enabled)
        #expect(fixture.state.alwaysAllowAgents)
        #expect(fixture.state.onboardingWatermark == 7)
        fixture.failWrites = true
        await #expect(throws: (any Error).self) { try await access.update(NativeAgentGrant(identity: .signed(identity))) }
        #expect(fixture.state.agentPermissions.count == 1)
    }

    private func record(team: String, identifier: String, expiration: Double? = nil) -> JSONValue {
        var signed: [String: JSONValue] = ["teamIdentifier": .string(team), "signingIdentifier": .string(identifier), "extra": .string("keep")]
        if let expiration { signed["expiration"] = .number(.double(expiration)) }
        return .object(["id": .string("existing-id"), "trust": .object(["signed": .object(signed)])])
    }
}

public struct NativePermissionFixtureState: Codable {
    var enabled = false
    var alwaysAllowAgents = false
    var version = 1
    var onboardingWatermark = 7
    var folderPermissions = ["existing-folder"]
    var agentPermissions: [Record] = []

    struct Record: Codable {
        var id: String
        var trust: Trust
    }
    struct Trust: Codable { var signed: Signed }
    struct Signed: Codable {
        var teamIdentifier: String
        var signingIdentifier: String
        var expiration: Date?
    }
}

public final class NativePermissionStoreFixture: NSObject {
    var state = NativePermissionFixtureState()
    var transactions = 0
    var failWrites = false

    @inline(never) public func withState<Value>(_ body: (inout NativePermissionFixtureState) throws -> Value) throws -> Value {
        if failWrites { throw NSError(domain: "NativePermissionStoreFixture", code: 1) }
        transactions += 1
        return try body(&state)
    }
}
