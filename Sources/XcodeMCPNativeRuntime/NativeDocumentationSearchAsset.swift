import Foundation

struct NativeDocumentationSearchAsset: Equatable {
    static let defaultRoot = URL(fileURLWithPath:
        "/System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation",
        isDirectory: true)
    static let configURLKey = "IDEChatDocumentationSearchConfigURL"

    let configURL: URL
    let xcodeVersion: String
    let documentationRelease: Int?

    static func configureLatest(
        in root: URL = defaultRoot,
        defaults: UserDefaults = .standard
    ) throws -> Self? {
        guard let asset = try latest(in: root) else { return nil }
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[configURLKey] = asset.configURL.path
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        return asset
    }

    static func latest(in root: URL) throws -> Self? {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return candidates.lazy
            .filter { $0.pathExtension == "asset" }
            .compactMap { asset(at: $0) }
            .max { lhs, rhs in
                let version = compareVersions(lhs.xcodeVersion, rhs.xcodeVersion)
                if version != .orderedSame { return version == .orderedAscending }
                let lhsRelease = lhs.documentationRelease ?? 0
                let rhsRelease = rhs.documentationRelease ?? 0
                if lhsRelease != rhsRelease { return lhsRelease < rhsRelease }
                return lhs.configURL.path > rhs.configURL.path
            }
    }

    private static func asset(at url: URL) -> Self? {
        let dataURL = url.appendingPathComponent("AssetData", isDirectory: true)
        let configURL = dataURL.appendingPathComponent("config.json")
        let indexURL = dataURL.appendingPathComponent("documentation-db/index.sql")
        guard FileManager.default.isReadableFile(atPath: configURL.path),
              FileManager.default.isReadableFile(atPath: indexURL.path),
              let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let info = try? PropertyListDecoder().decode(AssetInfo.self, from: data) else {
            return nil
        }
        return Self(configURL: configURL, xcodeVersion: info.properties.xcodeVersion,
                    documentationRelease: info.properties.documentationRelease)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let right = rhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue {
                return leftValue < rightValue ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private struct AssetInfo: Decodable {
        let properties: Properties

        enum CodingKeys: String, CodingKey {
            case properties = "MobileAssetProperties"
        }

        struct Properties: Decodable {
            let xcodeVersion: String
            let documentationRelease: Int?

            enum CodingKeys: String, CodingKey {
                case xcodeVersion = "XcodeVersion"
                case documentationRelease = "DocumentationRelease"
            }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                xcodeVersion = try fields.decode(String.self, forKey: .xcodeVersion)
                if let value = try? fields.decode(Int.self, forKey: .documentationRelease) {
                    documentationRelease = value
                } else if let value = try? fields.decode(String.self, forKey: .documentationRelease) {
                    documentationRelease = Int(value)
                } else {
                    documentationRelease = nil
                }
            }
        }
    }
}
