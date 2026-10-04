import Foundation
import Security
import XcodeMCPWire

package struct NativeSigningIdentity: Codable, Equatable, Sendable {
    package let teamIdentifier: String
    package let signingIdentifier: String

    package init(teamIdentifier: String, signingIdentifier: String) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    package var json: JSONValue {
        .object([
            "teamIdentifier": .string(teamIdentifier),
            "signingIdentifier": .string(signingIdentifier),
        ])
    }

    package static func read(executable: URL) throws -> Self? {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(executable as CFURL, [], &code))
        guard let code else {
            throw NativeRuntimeError.unavailable("The native helper has no code-signing object")
        }
        let validity = SecStaticCodeCheckValidity(code, [], nil)
        if validity == errSecCSUnsigned { return nil }
        try check(validity)
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let fields = information as? [String: Any],
              let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        return Self(teamIdentifier: team, signingIdentifier: identifier)
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Code-signing operation failed"
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
