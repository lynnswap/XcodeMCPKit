import Foundation

private struct TestDocumentationAssetInfoPlist: Encodable {
    let properties: TestDocumentationAssetProperties

    private enum CodingKeys: String, CodingKey {
        case properties = "MobileAssetProperties"
    }
}

private struct TestDocumentationAssetProperties: Encodable {
    let documentationRelease: String
    let xcodeVersion: String
    let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case documentationRelease = "DocumentationRelease"
        case xcodeVersion = "XcodeVersion"
        case osVersion = "OSVersion"
    }
}

package func makeInstalledDocumentationAsset(
    root: URL,
    name: String,
    xcodeVersion: String,
    osVersion: String,
    documentationRelease: Int,
    embeddingModelName: String? = nil
) throws {
    let assetURL = root.appendingPathComponent("\(name).asset", isDirectory: true)
    let assetDataURL = assetURL.appendingPathComponent("AssetData", isDirectory: true)
    let databaseURL = assetDataURL.appendingPathComponent("documentation-db", isDirectory: true)
    try FileManager.default.createDirectory(
        at: databaseURL,
        withIntermediateDirectories: true
    )
    let plist = TestDocumentationAssetInfoPlist(
        properties: TestDocumentationAssetProperties(
            documentationRelease: String(documentationRelease),
            xcodeVersion: xcodeVersion,
            osVersion: osVersion
        )
    )
    try PropertyListEncoder().encode(plist).write(
        to: assetURL.appendingPathComponent("Info.plist", isDirectory: false)
    )
    let config: [String: String] = embeddingModelName.map {
        ["embeddingModelName": $0]
    } ?? [:]
    try JSONEncoder().encode(config).write(
        to: assetDataURL.appendingPathComponent("config.json", isDirectory: false)
    )
    try Data().write(
        to: databaseURL.appendingPathComponent("index.sql", isDirectory: false)
    )
}
