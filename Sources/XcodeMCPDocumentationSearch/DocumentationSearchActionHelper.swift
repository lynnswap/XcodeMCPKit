extension LiveDocumentationSearchActionInvoker {
    func dvtInterface(target: String) -> String {
        """
        // swift-interface-format-version: 1.0
        // swift-module-flags: -target \(target) -enable-library-evolution -module-name DVTFoundation
        import Foundation

        public struct DVTStatelessActionProperty {
        }

        public protocol DVTStatelessActionType : Swift.Codable {
          static var schema: [DVTFoundation.DVTStatelessActionProperty] { get }
        }

        public protocol DVTStatelessAction {
          associatedtype Input : DVTFoundation.DVTStatelessActionType
          associatedtype Output : DVTFoundation.DVTStatelessActionType
          static var name: Swift.String { get }
          static var title: Swift.String { get }
          static var description: Swift.String { get }
          static func execute(input: Self.Input) async throws -> Self.Output
        }
        """
    }

    func chatInterface(target: String) -> String {
        """
        // swift-interface-format-version: 1.0
        // swift-module-flags: -target \(target) -enable-library-evolution -module-name IDEIntelligenceChat
        import Foundation
        import DVTFoundation

        public final class DocumentationSearchAction : DVTFoundation.DVTStatelessAction {
          public struct Input : DVTFoundation.DVTStatelessActionType, Swift.Codable {
            public var query: Swift.String
            public var frameworks: [Swift.String]?
            public init(query: Swift.String, frameworks: [Swift.String]?)
            public static var schema: [DVTFoundation.DVTStatelessActionProperty] { get }
          }

          public struct Output : DVTFoundation.DVTStatelessActionType, Swift.Codable {
            public struct Document : DVTFoundation.DVTStatelessActionType, Swift.Codable {
              public var title: Swift.String
              public var contents: Swift.String
              public var uri: Swift.String
              public var score: Swift.Double
              public var kind: Swift.String
              public static var schema: [DVTFoundation.DVTStatelessActionProperty] { get }
            }

            public var documents: [IDEIntelligenceChat.DocumentationSearchAction.Output.Document]
            public static var schema: [DVTFoundation.DVTStatelessActionProperty] { get }
          }

          public static var name: Swift.String { get }
          public static var title: Swift.String { get }
          public static var description: Swift.String { get }
          public static func execute(input: IDEIntelligenceChat.DocumentationSearchAction.Input) async throws -> IDEIntelligenceChat.DocumentationSearchAction.Output
          public init()
        }
        """
    }

    static let helperPackageManifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "DocumentationSearchActionHelperPackage",
            platforms: [
                .macOS("\(helperMacOSDeploymentTarget)"),
            ],
            products: [
                .executable(
                    name: "\(helperProductName)",
                    targets: ["DocumentationSearchActionHelper"]
                ),
            ],
            targets: [
                .executableTarget(
                    name: "DocumentationSearchActionHelper"
                ),
            ]
        )
        """

    static let helperSource = """
        import Foundation
        import IDEIntelligenceChat

        struct HelperRequest: Decodable {
            let query: String
            let frameworks: [String]?
            let configURL: String
            let maxResults: Int?
            let scoreThreshold: Double
        }

        @main
        struct DocumentationSearchActionHelper {
            static func main() async {
                do {
                    let inputData = FileHandle.standardInput.readDataToEndOfFile()
                    let request = try JSONDecoder().decode(HelperRequest.self, from: inputData)
                    var defaults: [String: Any] = [
                        "IDEChatDocumentationSearchConfigURL": request.configURL,
                        "IDEChatDocumentationSearchScoreThreshold": request.scoreThreshold,
                    ]
                    if let maxResults = request.maxResults {
                        defaults["IDEChatDocumentationSearchMaxResults"] = maxResults
                    }
                    UserDefaults.standard.setVolatileDomain(
                        defaults,
                        forName: UserDefaults.argumentDomain
                    )
                    let output = try await DocumentationSearchAction.execute(
                        input: DocumentationSearchAction.Input(
                            query: request.query,
                            frameworks: request.frameworks
                        )
                    )
                    let data = try JSONEncoder().encode(output)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data([0x0a]))
                } catch {
                    FileHandle.standardError.write(Data(String(describing: error).utf8))
                    FileHandle.standardError.write(Data([0x0a]))
                    exit(1)
                }
            }
        }
        """
}
