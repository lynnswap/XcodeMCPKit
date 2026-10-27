import Foundation

struct NativeCrashServiceQuery: Sendable {
    let adamIdentifier: String
    let bundleIdentifier: String
    let platformIdentifier: String
    let uploadPlatformIdentifier: String
    let appVersion: String?
    let isBeta: Bool?
    let timePeriod: String
    let pageIndex: Int
    let pageSize: Int
}
