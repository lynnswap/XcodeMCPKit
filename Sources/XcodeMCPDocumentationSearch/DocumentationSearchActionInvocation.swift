import Foundation
import NIOCore
import XcodeMCPCore

package struct DocumentationSearchActionOutput: Sendable, Codable, Equatable {
    package struct Document: Sendable, Codable, Equatable {
        package let title: String
        package let contents: String
        package let uri: String
        package let score: Double
        package let kind: String
    }

    package let documents: [Document]
}

package struct DocumentationSearchActionInvocation: Sendable, Equatable {
    package let installation: DocumentationSearchInstallation
    package let asset: DocumentationSearchInstalledAsset
    package let query: String
    package let frameworks: [String]
    package let limit: Int?
}

package protocol DocumentationSearchActionInvoking: Sendable {
    func isAvailable(for target: DocumentationSearchInstallation) async -> Bool
    func invoke(
        _ invocation: DocumentationSearchActionInvocation,
        timeout: TimeAmount?
    ) async throws -> DocumentationSearchActionOutput
}
