import Darwin
import Foundation

/// A `savedSamplesObserved` snapshot of Organizer's local files, rather than an exhaustive provider result.
/// The native identifier survives some symbolication changes; the stored content digest
/// identifies the version of the bytes. Missing saved files do not establish provider deletion.
struct NativeCrashLogSource: Sendable, Codable {
    struct Fingerprint: Sendable, Codable, Equatable {
        let byteCount: Int64
        let modificationDate: Date?
        let creationDate: Date?
        let resourceData: Data?
        let generationData: Data?
        let volumeUUID: String?
        let bootEpoch: String
    }

    let nativeID: String
    let url: URL
    let variant: String
    let occurredAt: Date?
    let byteCount: Int64
    let fingerprint: Fingerprint

    /// Prefers the same local symbolication variant that Organizer's log provider uses.
    /// A recognized native filename supplies the event date without reading any log bytes.
    static func inspect(rawURL: URL, includeHeaderDate: Bool = true) throws -> Self {
        let symbolicated = rawURL.deletingLastPathComponent().appending(component: "LocallySymbolicated")
            .appending(component: rawURL.lastPathComponent)
        let url: URL
        let variant: String
        let fingerprint: Fingerprint
        do {
            fingerprint = try Self.fingerprint(at: symbolicated)
            url = symbolicated
            variant = "locallySymbolicated"
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain,
                  [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) else { throw error }
            fingerprint = try Self.fingerprint(at: rawURL)
            url = rawURL
            variant = "raw"
        }
        let nativeID = rawURL.deletingPathExtension().lastPathComponent
        let occurredAt: Date?
        if let date = date(inNativeID: nativeID) { occurredAt = date }
        else { occurredAt = includeHeaderDate ? try headerDate(at: url) : nil }
        return Self(nativeID: nativeID, url: url, variant: variant, occurredAt: occurredAt,
            byteCount: fingerprint.byteCount, fingerprint: fingerprint)
    }

    /// Fetches uncached metadata for the copy's before/after checks. Unknown opaque
    /// identifier representations leave the streaming content hash as the source of truth.
    static func fingerprint(at url: URL) throws -> Fingerprint {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey, .fileResourceIdentifierKey,
            .generationIdentifierKey, .volumeUUIDStringKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw NativeRuntimeError.unsupportedContract("Organizer's saved crash sample is not a regular file: \(url.path)")
        }
        return Fingerprint(byteCount: Int64(size), modificationDate: values.contentModificationDate,
            creationDate: values.creationDate, resourceData: (values.fileResourceIdentifier as? NSData).map { Data(referencing: $0) },
            generationData: (values.generationIdentifier as? NSData).map { Data(referencing: $0) },
            volumeUUID: values.volumeUUIDString, bootEpoch: bootEpoch)
    }

    /// Resource identity is valid within one boot; generation identity detects data-fork
    /// changes for that file. Metadata-only timestamp changes do not require rereading it.
    static func matchesFingerprint(_ lhs: Fingerprint, _ rhs: Fingerprint) -> Bool {
        guard let resource = lhs.resourceData, let generation = lhs.generationData else { return false }
        return lhs.bootEpoch == rhs.bootEpoch && lhs.volumeUUID == rhs.volumeUUID
            && lhs.byteCount == rhs.byteCount && resource == rhs.resourceData && generation == rhs.generationData
    }

    private static func date(inNativeID identifier: String) -> Date? {
        guard let match = identifier.wholeMatch(of: /([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})(\.[0-9]+)?_([+-][0-9]{2})([0-9]{2})-[0-9a-f]{40}/) else { return nil }
        return date("\(match.1)T\(match.2):\(match.3):\(match.4)\(match.5 ?? "")\(match.6):\(match.7)")
    }

    private static func headerDate(at url: URL) throws -> Date? {
        let handle = try FileHandle(forReadingFrom: url)
        let data: Data
        do { data = try handle.read(upToCount: 16 * 1024) ?? Data() }
        catch {
            do { try handle.close() }
            catch let cleanupError {
                throw NSError(domain: "XcodeMCPKit.Organizer", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to read and close Organizer's saved crash sample",
                        NSMultipleUnderlyingErrorsKey: [error as NSError, cleanupError as NSError]])
            }
            throw error
        }
        try handle.close()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("Date/Time:") else { continue }
            let parts = line.dropFirst("Date/Time:".count).split(whereSeparator: \.isWhitespace)
            guard parts.count == 3 else { return nil }
            let zone = parts[2]
            guard zone.count == 5, zone.first == "+" || zone.first == "-" else { return nil }
            return date("\(parts[0])T\(parts[1])\(zone.prefix(3)):\(zone.suffix(2))")
        }
        return nil
    }

    private static func date(_ value: String) -> Date? {
        let fractional = value.contains(".")
        return try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: fractional).parse(value)
    }

    private static let bootEpoch: String = {
        var size = 0
        guard unsafe sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return "process:" + ProcessInfo.processInfo.globallyUniqueString
        }
        var bytes = Data(count: size)
        let result = unsafe bytes.withUnsafeMutableBytes { buffer in
            unsafe sysctlbyname("kern.bootsessionuuid", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0,
              let identifier = UUID(uuidString: String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)) else {
            return "process:" + ProcessInfo.processInfo.globallyUniqueString
        }
        return "boot:" + identifier.uuidString
    }()
}
