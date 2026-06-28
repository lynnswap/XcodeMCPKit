import Foundation
import XcodeMCPCore

enum ProxyFilesystemLocations {
    static let cacheRootEnv = Discovery.cacheRootEnvironmentVariable
    static let discoveryFileEnv = Discovery.discoveryFileEnvironmentVariable

    static func discoveryFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        Discovery.defaultFileURL(environment: environment, fileManager: fileManager)
    }
}
