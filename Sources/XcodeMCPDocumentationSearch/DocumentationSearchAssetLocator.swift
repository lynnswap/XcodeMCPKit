import Foundation
import NIOCore
import XcodeMCPCore

package struct DocumentationSearchInstalledAsset: Sendable, Equatable {
    package let assetURL: URL
    package let configURL: URL
    package let indexURL: URL
    package let databaseDirectoryURL: URL
    package let xcodeVersion: String
    package let osVersion: String
    package let documentationRelease: Int?
    package let embeddingModelName: String

    package init(
        assetURL: URL,
        configURL: URL,
        indexURL: URL,
        databaseDirectoryURL: URL,
        xcodeVersion: String,
        osVersion: String,
        documentationRelease: Int?,
        embeddingModelName: String
    ) {
        self.assetURL = assetURL
        self.configURL = configURL
        self.indexURL = indexURL
        self.databaseDirectoryURL = databaseDirectoryURL
        self.xcodeVersion = xcodeVersion
        self.osVersion = osVersion
        self.documentationRelease = documentationRelease
        self.embeddingModelName = embeddingModelName
    }
}

package struct DocumentationSearchAssetScan: Sendable, Equatable {
    package let root: String
    package let candidateCount: Int
    package let assets: [DocumentationSearchInstalledAsset]
    package let rejectionCounts: [String: Int]

    package init(
        root: String,
        candidateCount: Int,
        assets: [DocumentationSearchInstalledAsset],
        rejectionCounts: [String: Int]
    ) {
        self.root = root
        self.candidateCount = candidateCount
        self.assets = assets
        self.rejectionCounts = rejectionCounts
    }

    package var noAssetReason: String {
        var parts = [
            "no_installed_documentation_asset",
            "root=\(root)",
            "candidates=\(candidateCount)",
            "accepted=\(assets.count)",
        ]
        let rejected = rejectionCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key < rhs.key
            }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        if rejected.isEmpty == false {
            parts.append("rejected=\(rejected)")
        }
        return parts.joined(separator: " ")
    }
}

package enum DocumentationSearchAssetLocator {
    private enum AssetCandidate {
        case asset(DocumentationSearchInstalledAsset)
        case rejected(String)
    }

    package static let defaultAssetRoot = URL(
        fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation",
        isDirectory: true
    )

    package static func scanInstalledAssets(in root: URL) throws -> DocumentationSearchAssetScan {
        let assetURLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var candidateCount = 0
        var assets: [DocumentationSearchInstalledAsset] = []
        var rejectionCounts: [String: Int] = [:]
        for assetURL in assetURLs where assetURL.pathExtension == "asset" {
            candidateCount += 1
            switch installedAsset(at: assetURL) {
            case .asset(let asset):
                assets.append(asset)
            case .rejected(let reason):
                rejectionCounts[reason, default: 0] += 1
            }
        }
        return DocumentationSearchAssetScan(
            root: root.path,
            candidateCount: candidateCount,
            assets: assets,
            rejectionCounts: rejectionCounts
        )
    }

    private static func installedAsset(at assetURL: URL) -> AssetCandidate {
        let configURL = assetURL
            .appendingPathComponent("AssetData", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        let databaseDirectoryURL = assetURL
            .appendingPathComponent("AssetData", isDirectory: true)
            .appendingPathComponent("documentation-db", isDirectory: true)
        let indexURL = assetURL
            .appendingPathComponent("AssetData", isDirectory: true)
            .appendingPathComponent("documentation-db", isDirectory: true)
            .appendingPathComponent("index.sql", isDirectory: false)
        guard FileManager.default.isReadableFile(atPath: configURL.path) else {
            return .rejected("config_not_readable")
        }
        guard FileManager.default.isReadableFile(atPath: indexURL.path) else {
            return .rejected("index_not_readable")
        }

        let infoURL = assetURL.appendingPathComponent("Info.plist", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: infoURL)
        } catch {
            return .rejected("info_plist_not_readable")
        }
        let plist: AssetInfoPlist
        do {
            plist = try PropertyListDecoder().decode(AssetInfoPlist.self, from: data)
        } catch {
            return .rejected("info_plist_decode_failed")
        }
        let properties = plist.mobileAssetProperties
        let config = (try? JSONDecoder().decode(AssetConfig.self, from: Data(contentsOf: configURL)))
            ?? AssetConfig()

        return .asset(DocumentationSearchInstalledAsset(
            assetURL: assetURL,
            configURL: configURL,
            indexURL: indexURL,
            databaseDirectoryURL: databaseDirectoryURL,
            xcodeVersion: properties.xcodeVersion,
            osVersion: properties.osVersion,
            documentationRelease: properties.documentationRelease,
            embeddingModelName: config.embeddingModelName ?? "md7v2"
        ))
    }

    package static func bestHostCompatibleAsset(
        for targetXcodeVersion: String,
        currentOSVersion: String,
        from assets: [DocumentationSearchInstalledAsset]
    ) -> DocumentationSearchInstalledAsset? {
        hostCompatibleAssetsOrderedByCompatibility(
            for: targetXcodeVersion,
            currentOSVersion: currentOSVersion,
            from: assets
        ).first
    }

    package static func hostCompatibleAssetsOrderedByCompatibility(
        for targetXcodeVersion: String,
        currentOSVersion: String,
        from assets: [DocumentationSearchInstalledAsset]
    ) -> [DocumentationSearchInstalledAsset] {
        assets
            .filter {
                compareVersion($0.osVersion, currentOSVersion) != .orderedDescending
            }
            .sorted { lhs, rhs in
                isBetter(
                    lhs,
                    than: rhs,
                    targetXcodeVersion: targetXcodeVersion,
                    currentOSVersion: currentOSVersion
                )
            }
    }

    package static func latestAsset(
        from assets: [DocumentationSearchInstalledAsset]
    ) -> DocumentationSearchInstalledAsset? {
        assets.max { lhs, rhs in
            isNewer(rhs, than: lhs)
        }
    }

    private static func isNewer(
        _ lhs: DocumentationSearchInstalledAsset,
        than rhs: DocumentationSearchInstalledAsset
    ) -> Bool {
        let xcodeComparison = compareVersion(lhs.xcodeVersion, rhs.xcodeVersion)
        if xcodeComparison != .orderedSame {
            return xcodeComparison == .orderedDescending
        }
        let lhsDocumentationRelease = lhs.documentationRelease ?? 0
        let rhsDocumentationRelease = rhs.documentationRelease ?? 0
        if lhsDocumentationRelease != rhsDocumentationRelease {
            return lhsDocumentationRelease > rhsDocumentationRelease
        }
        let osComparison = compareVersion(lhs.osVersion, rhs.osVersion)
        if osComparison != .orderedSame {
            return osComparison == .orderedDescending
        }
        return lhs.assetURL.path < rhs.assetURL.path
    }

    private static func isBetter(
        _ lhs: DocumentationSearchInstalledAsset,
        than rhs: DocumentationSearchInstalledAsset,
        targetXcodeVersion: String,
        currentOSVersion: String
    ) -> Bool {
        let lhsRank = rank(lhs, targetXcodeVersion: targetXcodeVersion, currentOSVersion: currentOSVersion)
        let rhsRank = rank(rhs, targetXcodeVersion: targetXcodeVersion, currentOSVersion: currentOSVersion)
        if lhsRank.exactXcodeVersion != rhsRank.exactXcodeVersion {
            return lhsRank.exactXcodeVersion
        }
        if lhsRank.sameXcodeMajor != rhsRank.sameXcodeMajor {
            return lhsRank.sameXcodeMajor
        }
        if lhsRank.notNewerThanTargetXcode != rhsRank.notNewerThanTargetXcode {
            return lhsRank.notNewerThanTargetXcode
        }
        if lhsRank.xcodeVersionDistance != rhsRank.xcodeVersionDistance {
            return lhsRank.xcodeVersionDistance < rhsRank.xcodeVersionDistance
        }
        if lhsRank.osVersionDistance != rhsRank.osVersionDistance {
            return lhsRank.osVersionDistance < rhsRank.osVersionDistance
        }
        if lhsRank.documentationRelease != rhsRank.documentationRelease {
            return lhsRank.documentationRelease > rhsRank.documentationRelease
        }
        return lhs.assetURL.path < rhs.assetURL.path
    }

    private struct AssetRank {
        let exactXcodeVersion: Bool
        let sameXcodeMajor: Bool
        let notNewerThanTargetXcode: Bool
        let xcodeVersionDistance: Int
        let osVersionDistance: Int
        let documentationRelease: Int
    }

    private static func rank(
        _ asset: DocumentationSearchInstalledAsset,
        targetXcodeVersion: String,
        currentOSVersion: String
    ) -> AssetRank {
        let assetXcodeParts = numericVersionParts(asset.xcodeVersion)
        let targetXcodeParts = numericVersionParts(targetXcodeVersion)
        let assetOSParts = numericVersionParts(asset.osVersion)
        let currentOSParts = numericVersionParts(currentOSVersion)
        return AssetRank(
            exactXcodeVersion: compareVersion(asset.xcodeVersion, targetXcodeVersion) == .orderedSame,
            sameXcodeMajor: assetXcodeParts.first != nil && assetXcodeParts.first == targetXcodeParts.first,
            notNewerThanTargetXcode: compareVersion(asset.xcodeVersion, targetXcodeVersion) != .orderedDescending,
            xcodeVersionDistance: versionDistance(assetXcodeParts, targetXcodeParts),
            osVersionDistance: versionDistance(assetOSParts, currentOSParts),
            documentationRelease: asset.documentationRelease ?? 0
        )
    }

    package static func currentOperatingSystemVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericVersionParts(lhs)
        let rhsParts = numericVersionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }
        if lhsParts.isEmpty == false, rhsParts.isEmpty == false {
            return .orderedSame
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func numericVersionParts(_ version: String) -> [Int] {
        version
            .split { character in
                !character.isNumber
            }
            .compactMap { Int($0) }
    }

    private static func versionDistance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        guard lhs.isEmpty == false, rhs.isEmpty == false else {
            return Int.max
        }
        let count = max(lhs.count, rhs.count)
        var multiplier = 1
        var distance = 0
        for index in stride(from: count - 1, through: 0, by: -1) {
            let lhsValue = index < lhs.count ? lhs[index] : 0
            let rhsValue = index < rhs.count ? rhs[index] : 0
            distance += abs(lhsValue - rhsValue) * multiplier
            multiplier *= 1_000
        }
        return distance
    }

    private struct AssetInfoPlist: Decodable {
        let mobileAssetProperties: MobileAssetProperties

        private enum CodingKeys: String, CodingKey {
            case mobileAssetProperties = "MobileAssetProperties"
        }
    }

    private struct MobileAssetProperties: Decodable {
        let documentationRelease: Int?
        let xcodeVersion: String
        let osVersion: String

        private enum CodingKeys: String, CodingKey {
            case documentationRelease = "DocumentationRelease"
            case xcodeVersion = "XcodeVersion"
            case osVersion = "OSVersion"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            xcodeVersion = try container.decode(String.self, forKey: .xcodeVersion)
            osVersion = try container.decode(String.self, forKey: .osVersion)
            documentationRelease = Self.decodeDocumentationRelease(from: container)
        }

        private static func decodeDocumentationRelease(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Int? {
            if let value = try? container.decode(Int.self, forKey: .documentationRelease) {
                return value
            }
            if let value = try? container.decode(String.self, forKey: .documentationRelease) {
                return Int(value)
            }
            return nil
        }
    }

    private struct AssetConfig: Decodable {
        let embeddingModelName: String?

        init(embeddingModelName: String? = nil) {
            self.embeddingModelName = embeddingModelName
        }
    }
}
