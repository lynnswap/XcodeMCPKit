import Foundation
import MachOKit
import Security

@safe
@MainActor
struct NativePreviewEntitlements {
    let signed: Data?
    let simulator: Data?

    static func read(from bundle: URL) throws -> Self {
        guard let executable = Bundle(url: bundle)?.executableURL else {
            throw NativeRuntimeError.unsupportedContract("The preview product has no main executable: \(bundle.path)")
        }
        return try Self(signed: signedEntitlements(in: bundle),
                        simulator: simulatorEntitlements(in: executable))
    }

    private static func signedEntitlements(in bundle: URL) throws -> Data? {
        var code: SecStaticCode?
        let createStatus = unsafe SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        try check(createStatus, operation: "SecStaticCodeCreateWithPath", bundle: bundle)
        guard let code else {
            throw NativeRuntimeError.unsupportedContract("Security returned no code object for \(bundle.path)")
        }
        var information: CFDictionary?
        let informationStatus = unsafe SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        try check(informationStatus, operation: "SecCodeCopySigningInformation", bundle: bundle)
        guard let information = information as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("Security returned no signing information for \(bundle.path)")
        }
        guard let value = information[kSecCodeInfoEntitlementsDict as String] else {
            // CopySigningInformation also succeeds for unsigned products.
            guard information[kSecCodeInfoEntitlements as String] == nil else {
                throw NativeRuntimeError.unsupportedContract("The preview product has entitlements in an unsupported format: \(bundle.path)")
            }
            return nil
        }
        guard let entitlements = value as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("The preview product's signed entitlements are not a dictionary: \(bundle.path)")
        }
        return try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    }

    private static func simulatorEntitlements(in executable: URL) throws -> Data? {
        guard let file = try NativePreviewBinary.file(at: executable) else {
            throw NativeRuntimeError.unsupportedContract("The preview product has no arm64 executable: \(executable.path)")
        }
        guard let section = file.sections64.first(where: {
            $0.segmentName == "__TEXT" && $0.sectionName == "__entitlements"
        }) else { return nil }
        // Xcode stores Simulator capabilities here separately from the code signature.
        // Preserve the original bytes for the linker's -sectcreate input.
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        let start = section.offset
        guard start >= 0, section.size >= 0, start <= data.count, section.size <= data.count - start else {
            throw NativeRuntimeError.unsupportedContract("The preview product's Simulator entitlement section is truncated: \(executable.path)")
        }
        return data.subdata(in: start..<(start + section.size))
    }

    private static func check(_ status: OSStatus, operation: String, bundle: URL) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security error"
            throw NativeRuntimeError.invocation("\(operation) failed for \(bundle.path) (\(status)): \(message)")
        }
    }
}
