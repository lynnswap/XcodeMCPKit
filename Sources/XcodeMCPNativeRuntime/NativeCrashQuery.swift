import Foundation
import XcodeMCPWire

struct NativeCrashQuery: Sendable {
    let bundleIdentifier: String
    let platformIdentifier: String
    let uploadPlatformIdentifier: String
    let appVersion: String?
    let isBeta: Bool?
    let timePeriod: String
    let pageIndex: Int
    let pageSize: Int
    var collectsAllPages = false

    static func platformIdentifier(for description: String) throws -> String {
        guard let identifier = ["iOS": "com.apple.platform.iphoneos", "macOS": "com.apple.platform.macosx",
            "watchOS": "com.apple.platform.watchos", "tvOS": "com.apple.platform.appletvos",
            "visionOS": "com.apple.platform.xros"][description] else {
            throw NativeRuntimeError.invalidRequest("Unknown platform '\(description)'")
        }
        return identifier
    }

    func withPage(_ page: Int) -> Self {
        Self(bundleIdentifier: bundleIdentifier, platformIdentifier: platformIdentifier,
             uploadPlatformIdentifier: uploadPlatformIdentifier, appVersion: appVersion, isBeta: isBeta,
             timePeriod: timePeriod, pageIndex: page, pageSize: pageSize)
    }

    func json(issueID: String?) -> JSONValue {
        var value: [String: JSONValue] = ["bundleId": .string(bundleIdentifier),
            "platform": .string(platformIdentifier), "uploadPlatform": .string(uploadPlatformIdentifier),
            "appVersion": appVersion.map(JSONValue.string) ?? .null, "isBeta": isBeta.map(JSONValue.bool) ?? .null,
            "timePeriod": .string(timePeriod)]
        if let issueID { value["issueId"] = .string(issueID) }
        else {
            value["allPages"] = .bool(collectsAllPages)
            value["page"] = .number(.int(Int64(pageIndex)))
            value["pageSize"] = .number(.int(Int64(pageSize)))
        }
        return .object(value)
    }
}

struct NativeCrashServiceQuery: Sendable {
    let query: NativeCrashQuery
    let adamIdentifier: String

    func withPage(_ page: Int) -> Self {
        Self(query: query.withPage(page), adamIdentifier: adamIdentifier)
    }
}
