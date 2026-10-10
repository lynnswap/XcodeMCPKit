import Foundation
import XcodeMCPCore
import XcodeMCPInstallation

typealias XcodeHostInstallation = XcodeInstallation

extension XcodeInstallation {
    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "appPath": .string(appURL.path),
            "developerDirectory": .string(developerDirectory.path),
        ]
        if let version { fields["xcodeVersion"] = .string(version) }
        return fields
    }
}

struct XcodeHostInventory: Sendable {
    let defaultInstallation: XcodeHostInstallation
    let discover: @Sendable () async throws -> [XcodeHostInstallation]

    static func live(
        configuration: ProxyRuntimeConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let discovery = XcodeInstallationDiscovery.live
        let logger = ProxyLogging.make("installation")
        let installation = try discovery.resolve(preferred: configuration.developerDirectoryURL, environment: environment) {
            logger.notice("\($0)")
        }
        logger.info("Selected Xcode", metadata: ["app_path": .string(installation.appURL.path)])
        return Self(defaultInstallation: installation) {
            discovery.discover { logger.notice("\($0)") }
        }
    }
}

struct NativeHostBrokerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
