import Foundation
import Logging
import NIO
import SQLite3
import XcodeMCPDocumentationSearchPrivate
import XcodeMCPKit

enum DocumentationProvider {}

extension DocumentationProvider {
    enum ToolListUpdate: Sendable {
        case unchanged
        case unavailable
        case available(JSONValue)

        var debugLabel: String {
            switch self {
            case .unchanged:
                "unchanged"
            case .unavailable:
                "unavailable"
            case .available:
                "available"
            }
        }
    }
}

extension DocumentationProvider {
    enum UnavailableReason: Sendable, Error, CustomStringConvertible {
        case noAvailableProvider

        static let userFacingMessage =
            "DocumentationSearch is unavailable from the running Xcode documentation provider. Try restarting Xcode if the problem persists."

        var message: String {
            switch self {
            case .noAvailableProvider:
                Self.userFacingMessage
            }
        }

        var description: String {
            message
        }
    }
}

/// The manager's classification of one DocumentationSearch attempt.
/// When the manager is enabled, DocumentationSearch is owned by the
/// documentation provider and does not fall back to the regular upstream.
extension DocumentationProvider {
    enum CallOutcome: Sendable {
        case handled(Data, invalidatedProvider: Bool)
        case unavailable(DocumentationProvider.UnavailableReason)
        case failed(any Error, invalidatedProvider: Bool)
    }
}

protocol DocumentationProviderManaging: Sendable {
    func startBackgroundDiscovery(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate
    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome
    func invalidate(reason: String) async
    func shutdown() async
}

struct DocumentationSearchServiceRepairReport: Sendable, Equatable {
    let configURL: String
    let xcodeVersion: String
    let osVersion: String
    let documentationRelease: Int?
    let changedDefault: Bool

    init(
        configURL: String,
        xcodeVersion: String,
        osVersion: String,
        documentationRelease: Int?,
        changedDefault: Bool
    ) {
        self.configURL = configURL
        self.xcodeVersion = xcodeVersion
        self.osVersion = osVersion
        self.documentationRelease = documentationRelease
        self.changedDefault = changedDefault
    }
}

enum DocumentationSearchServiceRepairResult: Sendable, Equatable {
    case repaired(DocumentationSearchServiceRepairReport)
    case skipped(String)
    case failed(String)
}

protocol DocumentationSearchServiceRepairing: Sendable {
    func repairDocumentationSearch(
        for target: XcodeProcessTarget
    ) async -> DocumentationSearchServiceRepairResult
}

protocol DocumentationSearchProviding: Sendable {
    func descriptor(for target: XcodeProcessTarget) async -> JSONValue?
    func callDocumentationSearch(
        requestData: Data,
        for target: XcodeProcessTarget,
        timeout: TimeAmount?
    ) async throws -> Data
}

struct NoopDocumentationSearchServiceRepairer: DocumentationSearchServiceRepairing {
    init() {}

    func repairDocumentationSearch(
        for _: XcodeProcessTarget
    ) async -> DocumentationSearchServiceRepairResult {
        .skipped("disabled")
    }
}

struct UnavailableDocumentationSearchProvider: DocumentationSearchProviding {
    init() {}

    func descriptor(for _: XcodeProcessTarget) async -> JSONValue? {
        nil
    }

    func callDocumentationSearch(
        requestData _: Data,
        for _: XcodeProcessTarget,
        timeout _: TimeAmount?
    ) async throws -> Data {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }
}

enum DocumentationProviderRouteOwnership: Sendable, Equatable {
    case transportOwned
    case runtimeBorrowed(upstreamIndex: Int)
}

struct DocumentationProviderRoute: Sendable, Equatable {
    let id: String
    let target: XcodeProcessTarget
    let ownership: DocumentationProviderRouteOwnership
    let serverVersion: String

    var upstreamIndex: Int? {
        switch ownership {
        case .transportOwned:
            nil
        case .runtimeBorrowed(let upstreamIndex):
            upstreamIndex
        }
    }

    var isRuntimeBorrowed: Bool {
        switch ownership {
        case .runtimeBorrowed:
            true
        case .transportOwned:
            false
        }
    }

    init(
        id: String,
        target: XcodeProcessTarget,
        upstreamIndex: Int?,
        serverVersion: String = ""
    ) {
        self.id = id
        self.target = target
        self.ownership = upstreamIndex.map {
            .runtimeBorrowed(upstreamIndex: $0)
        } ?? .transportOwned
        self.serverVersion = serverVersion
    }
}

protocol DocumentationProviderRouting: Sendable {
    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout: TimeAmount?,
        initializeParams: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute
    func toolsList(
        route: DocumentationProviderRoute,
        timeout: TimeAmount?
    ) async throws -> JSONValue
    func callDocumentationSearch(
        route: DocumentationProviderRoute,
        requestData: Data,
        timeout: TimeAmount?
    ) async throws -> Data
    func close(route: DocumentationProviderRoute) async
    func closeForShutdown(route: DocumentationProviderRoute) async
    func shutdown() async
}

extension DocumentationProviderRouting {
    func close(route _: DocumentationProviderRoute) async {}
    func closeForShutdown(route: DocumentationProviderRoute) async {
        await close(route: route)
    }
    func shutdown() async {}
}

extension DocumentationProvider {
    enum ToolCatalog {
        static let toolName = "DocumentationSearch"

        static let proxyDescriptor: JSONValue = .object([
            "name": .string(toolName),
            "description": .string("Search Apple developer documentation."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Documentation search query."),
                    ]),
                ]),
                "required": .array([
                    .string("query"),
                ]),
            ]),
        ])

        static func applying(
            _ update: DocumentationProvider.ToolListUpdate,
            to result: JSONValue
        ) -> JSONValue {
            switch update {
            case .unchanged:
                return result
            case .unavailable:
                return removingDocumentationSearch(from: result)
            case .available(let descriptor):
                return replacingDocumentationSearch(in: result, with: descriptor)
            }
        }

        static func exposingProxyOwnedSearch(in result: JSONValue) -> JSONValue {
            replacingDocumentationSearch(in: result, with: proxyDescriptor)
        }

        static func descriptor(in result: JSONValue) -> JSONValue? {
            guard case .object(let object) = result,
                case .array(let tools)? = object["tools"]
            else {
                return nil
            }
            return tools.first { value in
                guard case .object(let toolObject) = value,
                    case .string(let name)? = toolObject["name"]
                else {
                    return false
                }
                return name == toolName
            }
        }

        static func responseIsDocumentationNotEnabled(_ data: Data) -> Bool {
            responseErrorTexts(in: data).contains { text in
                let normalized = text.lowercased()
                return normalized.contains("documentationsearch")
                    && normalized.contains("not enabled")
            }
        }

        static func responseIsDocumentationProviderFailure(_ data: Data) -> Bool {
            responseErrorTexts(in: data).contains { text in
                let normalized = text.lowercased()
                return normalized.contains("config.json")
                    || normalized.contains("documentation database")
                    || normalized.contains("asset is not installed")
                    || normalized.contains("unable to obtain asset location")
                    || normalized.contains("no matching asset")
                    || normalized.contains("cannot complete asset query")
                    || normalized.contains("cannot resolve asset query")
            }
        }

        private static func replacingDocumentationSearch(
            in result: JSONValue,
            with descriptor: JSONValue
        ) -> JSONValue {
            guard case .object(var object) = result,
                case .array(let tools)? = object["tools"]
            else {
                return result
            }
            var replaced = false
            var rewritten: [JSONValue] = []
            rewritten.reserveCapacity(tools.count + 1)
            for tool in tools {
                guard case .object(let toolObject) = tool,
                    case .string(let name)? = toolObject["name"],
                    name == toolName
                else {
                    rewritten.append(tool)
                    continue
                }
                if !replaced {
                    rewritten.append(descriptor)
                    replaced = true
                }
            }
            if !replaced {
                rewritten.append(descriptor)
            }
            object["tools"] = .array(rewritten)
            return .object(object)
        }

        private static func removingDocumentationSearch(from result: JSONValue) -> JSONValue {
            guard case .object(var object) = result,
                case .array(let tools)? = object["tools"]
            else {
                return result
            }
            object["tools"] = .array(
                tools.filter { tool in
                    guard case .object(let toolObject) = tool,
                        case .string(let name)? = toolObject["name"]
                    else {
                        return true
                    }
                    return name != toolName
                })
            return .object(object)
        }

        private static func responseErrorTexts(in data: Data) -> [String] {
            var texts = responseErrorObjects(in: data).compactMap { object in
                object["message"] as? String
            }
            texts += responseResultObjects(in: data).flatMap { object -> [String] in
                guard object["isError"] as? Bool == true else {
                    return []
                }
                guard let content = object["content"] as? [[String: Any]] else {
                    return []
                }
                return content.compactMap { $0["text"] as? String }
            }
            return texts
        }

        private static func responseErrorObjects(in data: Data) -> [[String: Any]] {
            guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
                return []
            }
            if let object = payload as? [String: Any],
                let error = object["error"] as? [String: Any]
            {
                return [error]
            }
            guard let array = payload as? [Any] else {
                return []
            }
            return array.compactMap { item in
                guard let object = item as? [String: Any] else { return nil }
                return object["error"] as? [String: Any]
            }
        }

        private static func responseResultObjects(in data: Data) -> [[String: Any]] {
            guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
                return []
            }
            if let object = payload as? [String: Any],
                let result = object["result"] as? [String: Any]
            {
                return [result]
            }
            guard let array = payload as? [Any] else {
                return []
            }
            return array.compactMap { item in
                guard let object = item as? [String: Any] else { return nil }
                return object["result"] as? [String: Any]
            }
        }
    }
}

protocol DocumentationProviderSessionMaking: Sendable {
    func startSession(for target: XcodeProcessTarget) async throws -> any UpstreamSession
}

struct LiveDocumentationProviderSessionFactory: DocumentationProviderSessionMaking {
    private let bridgeRuntimeConfig: MCPBridgeRuntime.Configuration
    private let baseEnvironment: [String: String]

    init(
        config: ProxyConfig,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.bridgeRuntimeConfig = config.mcpBridgeRuntimeConfiguration
        self.baseEnvironment = baseEnvironment
    }

    func startSession(for target: XcodeProcessTarget) async throws
        -> any UpstreamSession
    {
        try await MCPBridgeRuntime.startProcessBoundSession(
            config: bridgeRuntimeConfig,
            xcodeTarget: target,
            baseEnvironment: baseEnvironment
        )
    }
}

struct DocumentationSearchInstalledAsset: Sendable, Equatable {
    let assetURL: URL
    let configURL: URL
    let indexURL: URL
    let databaseDirectoryURL: URL
    let xcodeVersion: String
    let osVersion: String
    let documentationRelease: Int?
    let embeddingModelName: String

    init(
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

struct DocumentationSearchAssetScan: Sendable, Equatable {
    let root: String
    let candidateCount: Int
    let assets: [DocumentationSearchInstalledAsset]
    let rejectionCounts: [String: Int]

    init(
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

    var noAssetReason: String {
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

enum DocumentationSearchAssetLocator {
    private enum AssetCandidate {
        case asset(DocumentationSearchInstalledAsset)
        case rejected(String)
    }

    static let defaultAssetRoot = URL(
        fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation",
        isDirectory: true
    )

    static func scanInstalledAssets(in root: URL) throws -> DocumentationSearchAssetScan {
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

    static func bestAsset(
        for targetXcodeVersion: String,
        currentOSVersion: String,
        from assets: [DocumentationSearchInstalledAsset]
    ) -> DocumentationSearchInstalledAsset? {
        assets.max { lhs, rhs in
            isBetter(rhs, than: lhs, targetXcodeVersion: targetXcodeVersion, currentOSVersion: currentOSVersion)
        }
    }

    static func latestAsset(
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
        if lhsRank.notNewerThanCurrentOS != rhsRank.notNewerThanCurrentOS {
            return lhsRank.notNewerThanCurrentOS
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
        let notNewerThanCurrentOS: Bool
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
            notNewerThanCurrentOS: compareVersion(asset.osVersion, currentOSVersion) != .orderedDescending,
            osVersionDistance: versionDistance(assetOSParts, currentOSParts),
            documentationRelease: asset.documentationRelease ?? 0
        )
    }

    static func currentOperatingSystemVersionString() -> String {
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

struct LiveDocumentationSearchServiceRepairer: DocumentationSearchServiceRepairing {
    private static let xcodeDefaultsDomain = "com.apple.dt.Xcode"
    private static let configURLDefaultsKey = "IDEChatDocumentationSearchConfigURL"

    private let assetRoot: URL
    private let readConfigURLOverride: @Sendable () -> String?
    private let writeConfigURLOverride: @Sendable (String) -> Bool

    init(
        assetRoot: URL = DocumentationSearchAssetLocator.defaultAssetRoot,
        readConfigURLOverride: @escaping @Sendable () -> String? = Self.currentConfigURLOverride,
        writeConfigURLOverride: @escaping @Sendable (String) -> Bool = Self.writeConfigURLOverride
    ) {
        self.assetRoot = assetRoot
        self.readConfigURLOverride = readConfigURLOverride
        self.writeConfigURLOverride = writeConfigURLOverride
    }

    func repairDocumentationSearch(
        for target: XcodeProcessTarget
    ) async -> DocumentationSearchServiceRepairResult {
        let scan: DocumentationSearchAssetScan
        do {
            scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        } catch {
            return .failed("asset_scan_failed: \(error)")
        }
        guard let asset = DocumentationSearchAssetLocator.latestAsset(from: scan.assets) else {
            return .skipped(scan.noAssetReason)
        }

        let configURLString = asset.configURL.path
        let currentConfigURLString = readConfigURLOverride()
        guard currentConfigURLString != configURLString else {
            return .repaired(
                Self.report(for: asset, configURLString: configURLString, changedDefault: false)
            )
        }

        guard writeConfigURLOverride(configURLString) else {
            return .failed("defaults_write_failed")
        }
        return .repaired(
            Self.report(for: asset, configURLString: configURLString, changedDefault: true)
        )
    }

    private static func report(
        for asset: DocumentationSearchInstalledAsset,
        configURLString: String,
        changedDefault: Bool
    ) -> DocumentationSearchServiceRepairReport {
        DocumentationSearchServiceRepairReport(
            configURL: configURLString,
            xcodeVersion: asset.xcodeVersion,
            osVersion: asset.osVersion,
            documentationRelease: asset.documentationRelease,
            changedDefault: changedDefault
        )
    }

    private static func currentConfigURLOverride() -> String? {
        guard let value = CFPreferencesCopyAppValue(
            configURLDefaultsKey as CFString,
            xcodeDefaultsDomain as CFString
        ) else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return nil
    }

    private static func writeConfigURLOverride(_ value: String) -> Bool {
        CFPreferencesSetAppValue(
            configURLDefaultsKey as CFString,
            value as CFString,
            xcodeDefaultsDomain as CFString
        )
        return CFPreferencesAppSynchronize(xcodeDefaultsDomain as CFString)
    }
}

private final class DocumentationSearchServiceRepairWaiter: @unchecked Sendable {
    struct Result: Sendable {
        let repairResult: DocumentationSearchServiceRepairResult?
        let timedOut: Bool
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func wait(
        for task: Task<DocumentationSearchServiceRepairResult, Never>,
        timeout: TimeAmount,
        clock: ClockClient
    ) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                setContinuation(continuation)
                addTask(Task {
                    let result = await task.value
                    self.resume(Result(repairResult: result, timedOut: false))
                })
                addTask(Task {
                    await clock.sleep(.nanoseconds(timeout.nanoseconds))
                    guard Task.isCancelled == false else {
                        return
                    }
                    task.cancel()
                    self.resume(Result(repairResult: nil, timedOut: true))
                })
            }
        } onCancel: {
            task.cancel()
            resume(Result(repairResult: nil, timedOut: true))
        }
    }

    private func setContinuation(_ continuation: CheckedContinuation<Result, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            continuation.resume(returning: Result(repairResult: nil, timedOut: true))
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    private func resume(_ result: Result) {
        lock.lock()
        guard resolved == false else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks.removeAll()
        lock.unlock()

        for task in tasks {
            task.cancel()
        }
        continuation?.resume(returning: result)
    }
}

struct DocumentationAssetSemanticSearchResult: Sendable, Decodable, Equatable {
    let assetID: String
    let score: Double

    private enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case score
    }
}

private final class DocumentationSemanticSearchTimeoutWaiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        let resultToResume: Result<T, Error>?
        lock.lock()
        if let result {
            resultToResume = result
        } else {
            self.continuation = continuation
            resultToResume = nil
        }
        lock.unlock()

        if let resultToResume {
            continuation.resume(with: resultToResume)
        }
    }

    func resume(_ result: Result<T, Error>) {
        let continuationToResume: CheckedContinuation<T, Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuationToResume = continuation
        continuation = nil
        lock.unlock()

        continuationToResume?.resume(with: result)
    }
}

protocol DocumentationAssetSemanticSearching: Sendable {
    func isAvailable() -> Bool
    func search(
        asset: DocumentationSearchInstalledAsset,
        query: String,
        limit: Int,
        timeout: TimeAmount?
    ) async throws -> [DocumentationAssetSemanticSearchResult]
}

struct LiveDocumentationAssetSemanticSearcher: DocumentationAssetSemanticSearching {
    init() {}

    func isAvailable() -> Bool {
        XCDocSemanticSearchRuntimeAvailable() != 0
    }

    func search(
        asset: DocumentationSearchInstalledAsset,
        query: String,
        limit: Int,
        timeout: TimeAmount?
    ) async throws -> [DocumentationAssetSemanticSearchResult] {
        let timeoutSeconds: Double
        if let timeout, timeout.nanoseconds > 0 {
            timeoutSeconds = Double(timeout.nanoseconds) / 1_000_000_000.0
        } else {
            timeoutSeconds = 30
        }
        let databaseDirectoryPath = asset.databaseDirectoryURL.path
        let embeddingModelName = asset.embeddingModelName
        return try await Self.runBlockingSearch(timeout: timeout) {
            let json = try unsafe Self.copyResultJSON(
                databaseDirectoryPath: databaseDirectoryPath,
                embeddingModelName: embeddingModelName,
                query: query,
                limit: limit,
                timeoutSeconds: timeoutSeconds
            )
            guard let data = json.data(using: .utf8) else {
                return []
            }
            return try JSONDecoder().decode(
                [DocumentationAssetSemanticSearchResult].self,
                from: data
            )
        }
    }

    static func runBlockingSearch<T: Sendable>(
        timeout: TimeAmount?,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        guard timeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        let waiter = DocumentationSemanticSearchTimeoutWaiter<T>()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                waiter.resume(.success(try operation()))
            } catch {
                waiter.resume(.failure(error))
            }
        }

        if let timeout, timeout.nanoseconds > 0 {
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: timeout.nanoseconds))
            ) {
                waiter.resume(.failure(TimeoutError()))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.setContinuation(continuation)
            }
        } onCancel: {
            waiter.resume(.failure(CancellationError()))
        }
    }

    @unsafe private static func copyResultJSON(
        databaseDirectoryPath: String,
        embeddingModelName: String,
        query: String,
        limit: Int,
        timeoutSeconds: Double
    ) throws -> String {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let resultPointer = unsafe databaseDirectoryPath.withCString { databasePathPointer in
            unsafe embeddingModelName.withCString { embeddingModelNamePointer in
                unsafe query.withCString { queryPointer in
                    unsafe XCDocSemanticSearchCopyResultJSON(
                        databasePathPointer,
                        embeddingModelNamePointer,
                        queryPointer,
                        Int32(limit),
                        timeoutSeconds,
                        &errorPointer
                    )
                }
            }
        }
        defer {
            if let errorPointer = unsafe errorPointer {
                unsafe XCDocSemanticSearchFree(errorPointer)
            }
            if let resultPointer = unsafe resultPointer {
                unsafe XCDocSemanticSearchFree(resultPointer)
            }
        }
        guard let resultPointer = unsafe resultPointer else {
            let message: String
            if let errorPointer = unsafe errorPointer {
                message = unsafe String(cString: errorPointer)
            } else {
                message = "private semantic DocumentationSearch failed"
            }
            throw ControlPlane.Error.invalidResponse(message)
        }
        return unsafe String(cString: resultPointer)
    }
}

private struct DocumentationAssetSearchRow: Sendable, Equatable {
    let assetID: String?
    let type: String?
    let framework: String?
    let title: String?
    let content: String?
    let score: Double?
}

private actor DocumentationAssetSelectionCache {
    private struct RootSignature: Equatable {
        let path: String
        let modificationDate: Date?
    }

    private var cachedRootSignature: RootSignature?
    private var cachedAsset: DocumentationSearchInstalledAsset?

    func latestInstalledAsset(assetRoot: URL) -> DocumentationSearchInstalledAsset? {
        let signature = Self.rootSignature(for: assetRoot)
        if cachedRootSignature == signature, let cachedAsset {
            return cachedAsset
        }
        guard let scan = try? DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        else {
            return nil
        }
        guard let asset = DocumentationSearchAssetLocator.latestAsset(from: scan.assets) else {
            return nil
        }
        cachedRootSignature = signature
        cachedAsset = asset
        return asset
    }

    private static func rootSignature(for assetRoot: URL) -> RootSignature {
        let modificationDate = (try? FileManager.default.attributesOfItem(
            atPath: assetRoot.path
        )[.modificationDate]) as? Date
        return RootSignature(path: assetRoot.path, modificationDate: modificationDate)
    }
}

private actor DocumentationAssetSQLiteMaterializer {
    @safe private final class Connection {
        let path: String
        private var database: OpaquePointer?

        @unsafe init(path: String) throws {
            self.path = path
            var openedDatabase: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard unsafe sqlite3_open_v2(path, &openedDatabase, flags, nil) == SQLITE_OK else {
                let message = unsafe Self.errorMessage(openedDatabase)
                if let openedDatabase = unsafe openedDatabase {
                    unsafe sqlite3_close_v2(openedDatabase)
                }
                throw ControlPlane.Error.invalidResponse(
                    "local DocumentationSearch sqlite open failed: \(message)"
                )
            }
            unsafe database = openedDatabase
            try unsafe execute("PRAGMA temp_store = MEMORY")
            try unsafe execute("""
                CREATE TEMP TABLE IF NOT EXISTS xcode_mcp_ranked_doc_results (
                    rank INTEGER PRIMARY KEY,
                    asset_id TEXT NOT NULL,
                    score REAL NOT NULL
                )
                """)
        }

        deinit {
            if let database = unsafe database {
                unsafe sqlite3_close_v2(database)
            }
        }

        @unsafe func rows(
            rankedResults: [DocumentationAssetSemanticSearchResult],
            frameworks: [String],
            limit: Int
        ) throws -> [DocumentationAssetSearchRow] {
            guard rankedResults.isEmpty == false else {
                return []
            }
            let rankedResults = Self.deduplicatedRankedResults(rankedResults)
            try unsafe execute("DELETE FROM temp.xcode_mcp_ranked_doc_results")
            try unsafe insertRankedResults(rankedResults)

            let frameworkFilter = Set(frameworks.filter { $0.isEmpty == false })
            var rows: [DocumentationAssetSearchRow] = []
            let statement = try unsafe prepare("""
                SELECT a.asset_id AS asset_id,
                       a.type AS type,
                       a.framework AS framework,
                       a.title AS title,
                       substr(a.content, 1, 4000) AS content,
                       r.score AS score
                FROM temp.xcode_mcp_ranked_doc_results r
                JOIN attributes a
                  ON a.asset_id = r.asset_id
                 AND a.vector_id = (
                   SELECT MIN(a2.vector_id)
                   FROM attributes a2
                   WHERE a2.asset_id = r.asset_id
                     AND a2.title IS NOT NULL
                     AND a2.content IS NOT NULL
                 )
                WHERE a.title IS NOT NULL
                  AND a.content IS NOT NULL
                -- Preserve VectorSearch order to match mcpbridge DocumentationSearch ranking.
                ORDER BY r.rank
                """)
            defer { unsafe sqlite3_finalize(statement) }

            var stepResult = unsafe sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                let framework = unsafe Self.stringColumn(statement, 2)
                if frameworkFilter.isEmpty == false,
                   framework.map({ frameworkFilter.contains($0) }) != true
                {
                    stepResult = unsafe sqlite3_step(statement)
                    continue
                }
                let score: Double?
                if unsafe sqlite3_column_type(statement, 5) == SQLITE_NULL {
                    score = nil
                } else {
                    score = unsafe sqlite3_column_double(statement, 5)
                }
                rows.append(DocumentationAssetSearchRow(
                    assetID: unsafe Self.stringColumn(statement, 0),
                    type: unsafe Self.stringColumn(statement, 1),
                    framework: framework,
                    title: unsafe Self.stringColumn(statement, 3),
                    content: unsafe Self.stringColumn(statement, 4),
                    score: score
                ))
                if rows.count >= limit {
                    break
                }
                stepResult = unsafe sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE || rows.count >= limit
            else {
                throw ControlPlane.Error.invalidResponse(
                    "local DocumentationSearch sqlite query failed: \(unsafe Self.errorMessage(database))"
                )
            }
            return rows
        }

        private static func deduplicatedRankedResults(
            _ rankedResults: [DocumentationAssetSemanticSearchResult]
        ) -> [DocumentationAssetSemanticSearchResult] {
            var seenAssetIDs = Set<String>()
            var deduplicated: [DocumentationAssetSemanticSearchResult] = []
            deduplicated.reserveCapacity(rankedResults.count)
            for result in rankedResults where seenAssetIDs.insert(result.assetID).inserted {
                deduplicated.append(result)
            }
            return deduplicated
        }

        @unsafe private func insertRankedResults(
            _ rankedResults: [DocumentationAssetSemanticSearchResult]
        ) throws {
            let statement = try unsafe prepare("""
                INSERT INTO temp.xcode_mcp_ranked_doc_results(rank, asset_id, score)
                VALUES (?1, ?2, ?3)
                """)
            defer { unsafe sqlite3_finalize(statement) }

            for (index, result) in rankedResults.enumerated() {
                unsafe sqlite3_reset(statement)
                unsafe sqlite3_clear_bindings(statement)
                unsafe sqlite3_bind_int64(statement, 1, Int64(index))
                try unsafe bind(result.assetID, to: statement, index: 2)
                unsafe sqlite3_bind_double(statement, 3, result.score.isFinite ? result.score : 0)
                guard unsafe sqlite3_step(statement) == SQLITE_DONE else {
                    throw ControlPlane.Error.invalidResponse(
                        "local DocumentationSearch sqlite insert failed: \(unsafe Self.errorMessage(database))"
                    )
                }
            }
        }

        @unsafe private func execute(_ sql: String) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer {
                if let errorMessage = unsafe errorMessage {
                    unsafe sqlite3_free(errorMessage)
                }
            }
            guard unsafe sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                let message: String
                if let errorMessage = unsafe errorMessage {
                    message = unsafe String(cString: errorMessage)
                } else {
                    message = unsafe Self.errorMessage(database)
                }
                throw ControlPlane.Error.invalidResponse(
                    "local DocumentationSearch sqlite exec failed: \(message)"
                )
            }
        }

        @unsafe private func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard unsafe sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ControlPlane.Error.invalidResponse(
                    "local DocumentationSearch sqlite prepare failed: \(unsafe Self.errorMessage(database))"
                )
            }
            return unsafe statement
        }

        @unsafe private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) throws {
            let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let result = unsafe value.withCString { valuePointer in
                unsafe sqlite3_bind_text(statement, index, valuePointer, -1, transient)
            }
            guard result == SQLITE_OK else {
                throw ControlPlane.Error.invalidResponse(
                    "local DocumentationSearch sqlite bind failed: \(unsafe Self.errorMessage(database))"
                )
            }
        }

        @unsafe private static func stringColumn(
            _ statement: OpaquePointer?,
            _ index: Int32
        ) -> String? {
            guard let text = unsafe sqlite3_column_text(statement, index) else {
                return nil
            }
            return unsafe String(cString: text)
        }

        @unsafe private static func errorMessage(_ database: OpaquePointer?) -> String {
            guard let database = unsafe database,
                  let message = unsafe sqlite3_errmsg(database)
            else {
                return "unknown sqlite error"
            }
            return unsafe String(cString: message)
        }
    }

    private var connections: [String: Connection] = [:]

    func rows(
        asset: DocumentationSearchInstalledAsset,
        rankedResults: [DocumentationAssetSemanticSearchResult],
        frameworks: [String],
        limit: Int
    ) throws -> [DocumentationAssetSearchRow] {
        let path = asset.indexURL.path
        let connection: Connection
        if let cached = connections[path] {
            connection = cached
        } else {
            let opened = try unsafe Connection(path: path)
            connections[path] = opened
            connection = opened
        }
        return try unsafe connection.rows(
            rankedResults: rankedResults,
            frameworks: frameworks,
            limit: limit
        )
    }
}

struct LiveDocumentationAssetSearchProvider: DocumentationSearchProviding {
    private struct SearchArguments {
        let requestID: JSONRPC.ID
        let query: String
        let frameworks: [String]
        let limit: Int
    }

    private let assetRoot: URL
    private let semanticSearcher: any DocumentationAssetSemanticSearching
    private let assetCache: DocumentationAssetSelectionCache
    private let sqliteMaterializer: DocumentationAssetSQLiteMaterializer

    init(
        assetRoot: URL = DocumentationSearchAssetLocator.defaultAssetRoot,
        semanticSearcher: any DocumentationAssetSemanticSearching =
            LiveDocumentationAssetSemanticSearcher()
    ) {
        self.assetRoot = assetRoot
        self.semanticSearcher = semanticSearcher
        assetCache = DocumentationAssetSelectionCache()
        sqliteMaterializer = DocumentationAssetSQLiteMaterializer()
    }

    func descriptor(for _: XcodeProcessTarget) async -> JSONValue? {
        guard await latestInstalledAsset() != nil, semanticSearcher.isAvailable() else {
            return nil
        }
        return Self.descriptor
    }

    func callDocumentationSearch(
        requestData: Data,
        for target: XcodeProcessTarget,
        timeout: TimeAmount?
    ) async throws -> Data {
        guard timeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        let arguments = try Self.searchArguments(from: requestData)
        guard let asset = await latestInstalledAsset() else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        guard semanticSearcher.isAvailable() else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let deadline = Self.deadline(for: timeout)
        let rows = try await searchRows(
            arguments: arguments,
            asset: asset,
            deadline: deadline
        )
        return try Self.makeResponse(
            requestID: arguments.requestID,
            rows: rows
        )
    }

    private func latestInstalledAsset() async -> DocumentationSearchInstalledAsset? {
        await assetCache.latestInstalledAsset(assetRoot: assetRoot)
    }

    private func searchRows(
        arguments: SearchArguments,
        asset: DocumentationSearchInstalledAsset,
        deadline: UInt64?
    ) async throws -> [DocumentationAssetSearchRow] {
        var semanticLimit = Self.initialSemanticSearchLimit(for: arguments)
        let maxSemanticLimit = Self.maxSemanticSearchLimit(for: arguments)
        while true {
            let rankedResults = try await semanticSearcher.search(
                asset: asset,
                query: arguments.query,
                limit: semanticLimit,
                timeout: try Self.remainingTimeout(until: deadline)
            )
            guard rankedResults.isEmpty == false else {
                return []
            }
            let rows = try await sqliteMaterializer.rows(
                asset: asset,
                rankedResults: rankedResults,
                frameworks: arguments.frameworks,
                limit: arguments.limit
            )
            guard Self.shouldExpandSemanticSearch(
                arguments: arguments,
                rows: rows,
                rankedResultCount: rankedResults.count,
                semanticLimit: semanticLimit,
                maxSemanticLimit: maxSemanticLimit
            ) else {
                return rows
            }
            semanticLimit = min(semanticLimit * 2, maxSemanticLimit)
        }
    }

    private static var descriptor: JSONValue {
        .object([
            "name": .string(DocumentationProvider.ToolCatalog.toolName),
            "description": .string(
                "Searches installed Apple Developer Documentation."
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query."),
                    ]),
                    "frameworks": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                        ]),
                        "description": .string("Optional framework filter."),
                    ]),
                ]),
                "required": .array([
                    .string("query"),
                ]),
            ]),
        ])
    }

    private static func initialSemanticSearchLimit(for arguments: SearchArguments) -> Int {
        min(max(arguments.limit * 8, 40), 200)
    }

    private static func maxSemanticSearchLimit(for arguments: SearchArguments) -> Int {
        guard arguments.frameworks.contains(where: { $0.isEmpty == false }) else {
            return initialSemanticSearchLimit(for: arguments)
        }
        return min(max(arguments.limit * 128, 1_000), 2_000)
    }

    private static func shouldExpandSemanticSearch(
        arguments: SearchArguments,
        rows: [DocumentationAssetSearchRow],
        rankedResultCount: Int,
        semanticLimit: Int,
        maxSemanticLimit: Int
    ) -> Bool {
        arguments.frameworks.contains(where: { $0.isEmpty == false })
            && rows.count < arguments.limit
            && rankedResultCount >= semanticLimit
            && semanticLimit < maxSemanticLimit
    }

    private static func deadline(for timeout: TimeAmount?) -> UInt64? {
        guard let timeout, timeout.nanoseconds > 0 else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(UInt64(timeout.nanoseconds))
        return overflow ? UInt64.max : deadline
    }

    private static func remainingTimeout(until deadline: UInt64?) throws -> TimeAmount? {
        guard let deadline else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else {
            throw TimeoutError()
        }
        return .nanoseconds(Int64(clamping: deadline - now))
    }

    private static func searchArguments(from data: Data) throws -> SearchArguments {
        guard
            let object = try JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let requestID = JSONRPC.Message.Inspector.requestID(from: object)
        else {
            throw ControlPlane.Error.invalidResponse("missing DocumentationSearch request id")
        }
        guard
            let params = object["params"] as? [String: Any],
            let arguments = params["arguments"] as? [String: Any],
            let query = arguments["query"] as? String,
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ControlPlane.Error.invalidResponse("missing DocumentationSearch query")
        }
        let frameworks = Self.frameworks(from: arguments["frameworks"])
        let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 8, 1), 20)
        return SearchArguments(
            requestID: requestID,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            frameworks: frameworks,
            limit: limit
        )
    }

    private static func frameworks(from value: Any?) -> [String] {
        if let string = value as? String {
            return [string].filter { $0.isEmpty == false }
        }
        guard let array = value as? [Any] else {
            return []
        }
        return array.compactMap { $0 as? String }.filter { $0.isEmpty == false }
    }

    private static func makeResponse(
        requestID: JSONRPC.ID,
        rows: [DocumentationAssetSearchRow]
    ) throws -> Data {
        let documents = rows.map { row -> JSONValue in
            let type = row.type ?? ""
            let content = row.content ?? ""
            var document: [String: JSONValue] = [
                "title": .string(row.title ?? ""),
                "kind": .string(type),
                "contents": .string(content),
            ]
            if let assetID = row.assetID {
                document["uri"] = .string(assetID)
            }
            if let score = row.score {
                document["score"] = .number(.double(score))
            }
            return .object(document)
        }
        let structuredContent = JSONValue.object([
            "documents": .array(documents),
        ])
        let payloadData = try JSONSerialization.data(
            withJSONObject: structuredContent.foundationObject,
            options: [.sortedKeys]
        )
        let payloadText = String(decoding: payloadData, as: UTF8.self)
        return try JSONRPC.Wire.resultResponseData(
            id: requestID,
            result: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(payloadText),
                    ])
                ]),
                "structuredContent": structuredContent,
                "isError": .bool(false),
            ])
        )
    }
}

private final class DocumentationPendingResponse: @unchecked Sendable {
    let originalID: JSONRPC.ID
    let continuation: CheckedContinuation<Data, Error>
    var timeoutTask: Task<Void, Never>?

    init(originalID: JSONRPC.ID, continuation: CheckedContinuation<Data, Error>) {
        self.originalID = originalID
        self.continuation = continuation
    }
}

private final class DocumentationProviderManagerLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var shutdown = false

    var isShutdown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shutdown
    }

    func markShutdown() {
        lock.lock()
        shutdown = true
        lock.unlock()
    }
}

actor DocumentationProviderConnection {
    private let session: any UpstreamSession
    private let clock: ClockClient
    private let tasks = AsyncTaskSupervisor()
    private var eventTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pendingResponses: [String: DocumentationPendingResponse] = [:]
    private var nextID: Int64 = 1

    init(session: any UpstreamSession, clock: ClockClient = .liveValue) {
        self.session = session
        self.clock = clock
    }

    isolated deinit {
        eventTask?.cancel()
        tasks.cancelAll()
        failAll(CancellationError())
    }

    func start() {
        guard eventTask == nil else { return }
        let session = session
        eventTask = Task { [weak self, session] in
            for await event in session.events {
                await self?.handle(event)
            }
            await self?.failAll(UpstreamSlotScheduler.AcquisitionError.unavailable)
        }
    }

    func stopDetachingSession() -> Task<Void, Never> {
        ensureStopTask()
    }

    func stopAwaitingSession() async {
        await ensureStopTask().value
    }

    private func ensureStopTask() -> Task<Void, Never> {
        if let existing = stopTask {
            return existing
        }
        let eventTask = self.eventTask
        eventTask?.cancel()
        self.eventTask = nil
        let taskDrain = tasks.beginShutdown()
        failAll(CancellationError())
        let session = self.session
        let stopTask = Task {
            await session.stop()
            await eventTask?.value
            await taskDrain.wait()
        }
        self.stopTask = stopTask
        return stopTask
    }

    func sendNotification(_ object: [String: Any]) async throws {
        guard let data = try? JSONRPC.Wire.data(from: object) else {
            throw ControlPlane.Error.invalidResponse("invalid notification")
        }
        let result = await session.send(data)
        guard result == .accepted else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    func call(_ requestData: Data, timeout: TimeAmount?) async throws -> Data {
        guard
            var object = try JSONSerialization.jsonObject(with: requestData, options: [])
                as? [String: Any],
            let originalID = JSONRPC.Message.Inspector.requestID(from: object)
        else {
            throw ControlPlane.Error.invalidResponse("missing DocumentationSearch request id")
        }

        let upstreamID = nextID
        let upstreamIDKey = String(upstreamID)
        nextID += 1
        object = JSONRPC.Wire.objectByReplacingID(
            in: object,
            with: JSONRPC.ID(any: NSNumber(value: upstreamID))!
        )
        guard let upstreamData = try? JSONRPC.Wire.data(from: object) else {
            throw ControlPlane.Error.invalidResponse("invalid DocumentationSearch request")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = DocumentationPendingResponse(
                    originalID: originalID,
                    continuation: continuation
                )
                pendingResponses[upstreamIDKey] = pending
                scheduleTimeoutIfNeeded(id: upstreamIDKey, timeout: timeout, pending: pending)

                let scheduled = tasks.run { [weak self, session] in
                    let sendResult = await session.send(upstreamData)
                    guard sendResult == .accepted else {
                        await self?.failPending(
                            id: upstreamIDKey,
                            error: UpstreamSlotScheduler.AcquisitionError.unavailable)
                        return
                    }
                }
                if !scheduled {
                    failPending(
                        id: upstreamIDKey,
                        error: UpstreamSlotScheduler.AcquisitionError.unavailable
                    )
                }
            }
        } onCancel: {
            tasks.run { [weak self] in
                await self?.failPending(id: upstreamIDKey, error: CancellationError())
            }
        }
    }

    private func scheduleTimeoutIfNeeded(
        id: String,
        timeout: TimeAmount?,
        pending: DocumentationPendingResponse
    ) {
        guard let timeout, timeout.nanoseconds > 0 else {
            return
        }
        pending.timeoutTask = Task { [weak self, clock] in
            await clock.sleep(.nanoseconds(timeout.nanoseconds))
            guard Task.isCancelled == false else {
                return
            }
            await self?.failPending(id: id, error: TimeoutError())
        }
    }

    private func handle(_ event: Upstream.Event) {
        switch event {
        case .message(let data):
            handleMessage(data)
        case .exit, .stdoutProtocolViolation:
            failAll(UpstreamSlotScheduler.AcquisitionError.unavailable)
        case .stderr, .stdoutBufferSize:
            break
        }
    }

    private func handleMessage(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let responseID = JSONRPC.Message.Inspector.responseID(from: object),
            let pending = pendingResponses.removeValue(forKey: responseID.key)
        else {
            return
        }

        pending.timeoutTask?.cancel()
        guard let rewrittenData = try? JSONRPC.Wire.dataByReplacingID(
            in: object,
            with: pending.originalID
        ) else {
            pending.continuation.resume(
                throwing: ControlPlane.Error.invalidResponse("invalid DocumentationSearch response")
            )
            return
        }
        pending.continuation.resume(returning: rewrittenData)
    }

    private func failPending(id: String, error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        for item in pending.values {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: error)
        }
    }
}

struct SessionBackedDocumentationProviderTransportTestHooks: Sendable {
    var shutdownWillAwaitDetachedSessionStops: @Sendable (_ stopCount: Int) -> Void

    init(
        shutdownWillAwaitDetachedSessionStops: @escaping @Sendable (_ stopCount: Int) -> Void = { _ in }
    ) {
        self.shutdownWillAwaitDetachedSessionStops = shutdownWillAwaitDetachedSessionStops
    }

    static let noop = Self()
}

actor SessionBackedDocumentationProviderTransport: DocumentationProviderRouting {
    private let sessionFactory: any DocumentationProviderSessionMaking
    private let clock: ClockClient
    private let testHooks: SessionBackedDocumentationProviderTransportTestHooks
    private var connections: [String: DocumentationProviderConnection] = [:]
    private var backgroundSessionStops: [UUID: Task<Void, Never>] = [:]

    init(
        sessionFactory: any DocumentationProviderSessionMaking,
        clock: ClockClient = .liveValue,
        testHooks: SessionBackedDocumentationProviderTransportTestHooks = .noop
    ) {
        self.sessionFactory = sessionFactory
        self.clock = clock
        self.testHooks = testHooks
    }

    isolated deinit {
        connections.removeAll()
        backgroundSessionStops.removeAll()
    }

    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout: TimeAmount?,
        initializeParams: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        let session = try await sessionFactory.startSession(for: target)
        let connection = DocumentationProviderConnection(session: session, clock: clock)
        let routeID = UUID().uuidString
        do {
            await connection.start()
            let initialize = try await connection.call(
                try Self.makeInitializeRequestData(initializeParams: initializeParams),
                timeout: requestTimeout
            )
            let serverVersion = DocumentationProviderManager.serverVersion(
                fromInitializeResponse: initialize
            ) ?? ""
            try await connection.sendNotification(
                JSONRPC.Wire.notificationObject(method: "notifications/initialized")
            )
            connections[routeID] = connection
            return DocumentationProviderRoute(
                id: routeID,
                target: target,
                upstreamIndex: nil,
                serverVersion: serverVersion
            )
        } catch {
            let stopTask = await connection.stopDetachingSession()
            trackBackgroundSessionStop(stopTask)
            throw error
        }
    }

    func toolsList(
        route: DocumentationProviderRoute,
        timeout: TimeAmount?
    ) async throws -> JSONValue {
        guard let connection = connections[route.id] else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let toolsList = try await connection.call(
            try Self.makeToolsListRequestData(),
            timeout: timeout
        )
        return try DocumentationProviderManager.resultValue(from: toolsList)
    }

    func callDocumentationSearch(
        route: DocumentationProviderRoute,
        requestData: Data,
        timeout: TimeAmount?
    ) async throws -> Data {
        guard let connection = connections[route.id] else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        return try await connection.call(requestData, timeout: timeout)
    }

    func close(route: DocumentationProviderRoute) async {
        guard let connection = connections.removeValue(forKey: route.id) else {
            return
        }
        let stopTask = await connection.stopDetachingSession()
        trackBackgroundSessionStop(stopTask)
    }

    func closeForShutdown(route: DocumentationProviderRoute) async {
        guard let connection = connections.removeValue(forKey: route.id) else {
            return
        }
        await connection.stopAwaitingSession()
    }

    func shutdown() async {
        let connections = self.connections
        self.connections.removeAll()
        let backgroundSessionStops = self.backgroundSessionStops
        self.backgroundSessionStops.removeAll()
        if !backgroundSessionStops.isEmpty {
            testHooks.shutdownWillAwaitDetachedSessionStops(backgroundSessionStops.count)
        }
        for connection in connections.values {
            await connection.stopAwaitingSession()
        }
        for stopTask in backgroundSessionStops.values {
            await stopTask.value
        }
    }

    private func trackBackgroundSessionStop(_ stopTask: Task<Void, Never>) {
        let id = UUID()
        backgroundSessionStops[id] = stopTask
        Task { [weak self] in
            await stopTask.value
            await self?.finishBackgroundSessionStop(id)
        }
    }

    private func finishBackgroundSessionStop(_ id: UUID) {
        backgroundSessionStops.removeValue(forKey: id)
    }

    private static func makeInitializeRequestData(
        initializeParams: [String: JSONValue]
    ) throws -> Data {
        try JSONRPC.Wire.data(
            from: JSONRPC.Wire.requestObject(
                id: "initialize",
                method: "initialize",
                params: .object(initializeParams)
            )
        )
    }

    private static func makeToolsListRequestData() throws -> Data {
        try JSONRPC.Wire.data(
            from: JSONRPC.Wire.requestObject(
                id: "tools-list",
                method: "tools/list"
            )
        )
    }
}

struct DocumentationProviderManagerTestHooks: Sendable {
    var providerPreparationReused: @Sendable (pid_t) -> Void
    var providerPreparationWaitTimedOut: @Sendable (pid_t) -> Void
    var managerDeinitialized: @Sendable () -> Void

    init(
        providerPreparationReused: @escaping @Sendable (pid_t) -> Void = { _ in },
        providerPreparationWaitTimedOut: @escaping @Sendable (pid_t) -> Void = { _ in },
        managerDeinitialized: @escaping @Sendable () -> Void = {}
    ) {
        self.providerPreparationReused = providerPreparationReused
        self.providerPreparationWaitTimedOut = providerPreparationWaitTimedOut
        self.managerDeinitialized = managerDeinitialized
    }

    static let noop = Self()
}

actor DocumentationProviderManager: DocumentationProviderManaging {
    private enum CandidateBackend: Sendable {
        case xcode(route: DocumentationProviderRoute, descriptor: JSONValue?)
        case installedDocumentationAsset(descriptor: JSONValue)

        var descriptor: JSONValue? {
            switch self {
            case .xcode(_, let descriptor):
                descriptor
            case .installedDocumentationAsset(let descriptor):
                descriptor
            }
        }

        var route: DocumentationProviderRoute? {
            switch self {
            case .xcode(let route, _):
                route
            case .installedDocumentationAsset:
                nil
            }
        }

        var usesInstalledDocumentationAsset: Bool {
            switch self {
            case .installedDocumentationAsset:
                true
            case .xcode:
                false
            }
        }
    }

    private struct CandidateProfile: Sendable {
        let id: UUID
        let target: XcodeProcessTarget
        var backend: CandidateBackend
        let serverVersion: String
        var descriptorLookupCompleted: Bool

        var descriptor: JSONValue? {
            backend.descriptor
        }

        var route: DocumentationProviderRoute? {
            backend.route
        }
    }

    private struct ActiveProvider: Sendable {
        let profile: CandidateProfile
    }

    private struct ProviderPreparation: Sendable {
        let task: Task<CandidateProfile, Error>
    }

    private struct InstalledDocumentationAssetFallback: Sendable {
        let responseData: Data
        let descriptor: JSONValue
    }

    private static let installedDocumentationAssetStandaloneTarget = XcodeProcessTarget(
        processID: 0,
        appPath: "installed-documentation-asset",
        developerDir: "installed-documentation-asset",
        mcpbridgePath: "installed-documentation-asset",
        xcodeVersion: "installed-documentation-asset"
    )

    private struct ProviderPreparationContext: Sendable {
        let transport: any DocumentationProviderRouting
        let initializeParams: [String: JSONValue]
        let localSearchProvider: any DocumentationSearchProviding
        let preferLocalSearchProvider: Bool
        let clock: ClockClient
        let logger: Logger
        let lifecycle: DocumentationProviderManagerLifecycle

        func openProviderRoute(
            target: XcodeProcessTarget,
            requestTimeout: TimeAmount?
        ) async throws -> CandidateProfile {
            guard !lifecycle.isShutdown else {
                throw CancellationError()
            }
            logger.debug(
                "Preparing documentation provider candidate",
                metadata: [
                    "pid": .string("\(target.processID)"),
                    "app_path": .string(target.appPath),
                    "xcode_version": .string(target.xcodeVersion),
                ]
            )
            let startupDeadline = Deadline.fromNow(requestTimeout ?? .seconds(30), clock: clock)
            try Task.checkCancellation()
            let startupTimeout = remainingTimeout(until: startupDeadline)
            guard startupTimeout?.nanoseconds != 0 else {
                throw TimeoutError()
            }
            let route: DocumentationProviderRoute
            do {
                route = try await transport.openRoute(
                    for: target,
                    requestTimeout: startupTimeout,
                    initializeParams: initializeParams
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let localProfile = await installedDocumentationAssetPrimaryProfile(for: target) {
                    return localProfile
                }
                throw error
            }
            do {
                try Task.checkCancellation()
                guard !lifecycle.isShutdown else {
                    throw CancellationError()
                }
                guard remainingTimeout(until: startupDeadline)?.nanoseconds != 0 else {
                    throw TimeoutError()
                }
            } catch {
                if lifecycle.isShutdown {
                    await transport.closeForShutdown(route: route)
                } else {
                    await transport.close(route: route)
                }
                throw error
            }
            return CandidateProfile(
                id: UUID(),
                target: target,
                backend: .xcode(route: route, descriptor: nil),
                serverVersion: route.serverVersion,
                descriptorLookupCompleted: false
            )
        }

        private func installedDocumentationAssetPrimaryProfile(
            for target: XcodeProcessTarget
        ) async -> CandidateProfile? {
            guard let descriptor = await localSearchProvider.descriptor(for: target) else {
                return nil
            }
            logger.info(
                "Using installed documentation asset as primary DocumentationSearch provider",
                metadata: [
                    "pid": .string("\(target.processID)"),
                    "app_path": .string(target.appPath),
                    "xcode_version": .string(target.xcodeVersion),
                ]
            )
            return CandidateProfile(
                id: UUID(),
                target: target,
                backend: .installedDocumentationAsset(descriptor: descriptor),
                serverVersion: "installed-documentation-asset",
                descriptorLookupCompleted: true
            )
        }

        private func remainingTimeout(until deadline: Deadline?) -> TimeAmount? {
            guard let deadline else {
                return nil
            }
            return deadline.remaining()
        }
    }

    private struct PreparationWaitTimedOut: Error {}

    private final class PreparationWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CandidateProfile, Error>?
        private var tasks: [Task<Void, Never>] = []
        private var resolved = false

        func setContinuation(_ continuation: CheckedContinuation<CandidateProfile, Error>) {
            lock.lock()
            if resolved {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func addTask(_ task: Task<Void, Never>) {
            lock.lock()
            if resolved {
                lock.unlock()
                task.cancel()
                return
            }
            tasks.append(task)
            lock.unlock()
        }

        func resume(_ result: Result<CandidateProfile, Error>) {
            lock.lock()
            guard resolved == false else {
                lock.unlock()
                return
            }
            resolved = true
            let continuation = continuation
            self.continuation = nil
            let tasks = tasks
            self.tasks.removeAll()
            lock.unlock()

            for task in tasks {
                task.cancel()
            }
            switch result {
            case .success(let profile):
                continuation?.resume(returning: profile)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
        }
    }

    private let discovery: any XcodeTargetDiscovering
    private let transport: any DocumentationProviderRouting
    private let providerSelectionTimeout: TimeAmount?
    private let initializeParams: [String: JSONValue]
    private let serviceRepairer: any DocumentationSearchServiceRepairing
    private let localSearchProvider: any DocumentationSearchProviding
    private let preferLocalSearchProvider: Bool
    private let clock: ClockClient
    private let testHooks: DocumentationProviderManagerTestHooks
    private let logger: Logger
    private let lifecycle = DocumentationProviderManagerLifecycle()
    private let descriptorRefreshRetryDelayNanoseconds: Int64 = 250_000_000
    private let candidateAttemptTimeoutNanoseconds: Int64 = 2_000_000_000
    private var activeProvider: ActiveProvider?
    private var preparedProviders: [pid_t: CandidateProfile] = [:]
    private var providerPreparations: [pid_t: ProviderPreparation] = [:]
    private var permanentlyUnusableProcessIDs: Set<pid_t> = []
    private var serviceRepairAttemptedProcessIDs: Set<pid_t> = []
    private var isShutdown = false

    init(
        discovery: any XcodeTargetDiscovering,
        transport: any DocumentationProviderRouting,
        providerSelectionTimeout: TimeAmount? = .seconds(30),
        initializeParams: [String: JSONValue] = InitializeHandshakeJSON.defaultParams(),
        serviceRepairer: any DocumentationSearchServiceRepairing = NoopDocumentationSearchServiceRepairer(),
        localSearchProvider: any DocumentationSearchProviding = UnavailableDocumentationSearchProvider(),
        preferLocalSearchProvider: Bool = false,
        clock: ClockClient = .liveValue,
        testHooks: DocumentationProviderManagerTestHooks = .noop,
        logger: Logger = ProxyLogging.make("documentation.provider")
    ) {
        self.discovery = discovery
        self.transport = transport
        self.providerSelectionTimeout = providerSelectionTimeout
        self.initializeParams = initializeParams
        self.serviceRepairer = serviceRepairer
        self.localSearchProvider = localSearchProvider
        self.preferLocalSearchProvider = preferLocalSearchProvider
        self.clock = clock
        self.testHooks = testHooks
        self.logger = logger
    }

    isolated deinit {
        lifecycle.markShutdown()
        for preparation in providerPreparations.values {
            preparation.task.cancel()
        }
        providerPreparations.removeAll()
        preparedProviders.removeAll()
        activeProvider = nil
        permanentlyUnusableProcessIDs.removeAll()
        testHooks.managerDeinitialized()
    }

    init(
        discovery: any XcodeTargetDiscovering,
        sessionFactory: any DocumentationProviderSessionMaking,
        providerSelectionTimeout: TimeAmount? = .seconds(30),
        initializeParams: [String: JSONValue] = InitializeHandshakeJSON.defaultParams(),
        serviceRepairer: any DocumentationSearchServiceRepairing = NoopDocumentationSearchServiceRepairer(),
        localSearchProvider: any DocumentationSearchProviding = UnavailableDocumentationSearchProvider(),
        preferLocalSearchProvider: Bool = false,
        clock: ClockClient = .liveValue,
        testHooks: DocumentationProviderManagerTestHooks = .noop,
        logger: Logger = ProxyLogging.make("documentation.provider")
    ) {
        self.init(
            discovery: discovery,
            transport: SessionBackedDocumentationProviderTransport(
                sessionFactory: sessionFactory,
                clock: clock
            ),
            providerSelectionTimeout: providerSelectionTimeout,
            initializeParams: initializeParams,
            serviceRepairer: serviceRepairer,
            localSearchProvider: localSearchProvider,
            preferLocalSearchProvider: preferLocalSearchProvider,
            clock: clock,
            testHooks: testHooks,
            logger: logger
        )
    }

    func startBackgroundDiscovery(requestTimeout: TimeAmount?) async
        -> DocumentationProvider.ToolListUpdate
    {
        guard !isShutdown else { return .unavailable }
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        let deadline = Deadline.fromNow(requestTimeout, clock: clock)
        if preferLocalSearchProvider {
            let localUpdate = await installedDocumentationAssetToolListUpdate()
            if case .available = localUpdate {
                return localUpdate
            }
        }
        let targets = orderedTargets(excluding: [])
        guard targets.isEmpty == false else {
            return .unavailable
        }
        for (index, target) in targets.enumerated() {
            guard !Task.isCancelled, !isShutdown else {
                return .unavailable
            }
            do {
                let profile = try await preparedProvider(
                    for: target,
                    requestTimeout: timeoutForCandidate(
                        until: deadline,
                        remainingCandidateCount: targets.count - index
                    ),
                    fetchDescriptor: true
                )
                if let descriptor = profile.descriptor {
                    let didPromote = await promoteToActive(profile)
                    if didPromote {
                        logger.info(
                            "Prewarmed documentation provider",
                            metadata: [
                                "pid": .string("\(target.processID)"),
                                "app_path": .string(target.appPath),
                                "xcode_version": .string(target.xcodeVersion),
                                "server_version": .string(profile.serverVersion),
                            ]
                        )
                    }
                    return .available(descriptor)
                }
                logger.info(
                    "Documentation provider candidate did not advertise DocumentationSearch; trying next candidate",
                    metadata: [
                        "pid": .string("\(target.processID)"),
                        "app_path": .string(target.appPath),
                        "xcode_version": .string(target.xcodeVersion),
                    ]
                )
                permanentlyUnusableProcessIDs.insert(target.processID)
                await discardPreparedProvider(profile)
                continue
            } catch is CancellationError {
                return .unavailable
            } catch {
                logger.debug(
                    "Documentation provider background discovery candidate rejected",
                    metadata: candidateLogMetadata(target: target, error: error)
                )
                continue
            }
        }
        return await installedDocumentationAssetToolListUpdate()
    }

    func toolListUpdate(requestTimeout: TimeAmount?) async
        -> DocumentationProvider.ToolListUpdate
    {
        guard !isShutdown else {
            return .unavailable
        }
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        guard !Task.isCancelled else {
            return .unavailable
        }
        if preferLocalSearchProvider {
            let localUpdate = await installedDocumentationAssetToolListUpdate()
            if case .available = localUpdate {
                return localUpdate
            }
        }
        let cached = toolListUpdateFromCachedState(requestTimeout: requestTimeout)
        if case .unchanged = cached {
            return await startBackgroundDiscovery(requestTimeout: requestTimeout)
        }
        return cached
    }

    private func toolListUpdateFromCachedState(requestTimeout: TimeAmount?)
        -> DocumentationProvider.ToolListUpdate
    {
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        if let activeProvider {
            guard activeProviderIsCurrentBest(activeProvider, excluding: []) else {
                return .unchanged
            }
            guard let descriptor = activeProvider.profile.descriptor else {
                return .unchanged
            }
            return .available(descriptor)
        }
        let targets = orderedTargets(excluding: [])
        guard targets.isEmpty == false else {
            return .unavailable
        }
        guard let firstTarget = targets.first else {
            return .unavailable
        }
        if let descriptor = preparedProviders[firstTarget.processID]?.descriptor {
            return .available(descriptor)
        }
        return .unchanged
    }

    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome {
        guard !isShutdown else {
            return .unavailable(.noAvailableProvider)
        }
        let deadline = Deadline.fromNow(requestTimeoutOverride, clock: clock)
        var rejectedProcessIDs: Set<pid_t> = []
        var invalidatedProvider = false
        var lastCandidateFailure: (any Error)?
        var attemptedPrimaryInstalledAsset = false

        while !Task.isCancelled {
            if let deadline, deadline.hasExpired {
                return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
            }
            if preferLocalSearchProvider, attemptedPrimaryInstalledAsset == false {
                attemptedPrimaryInstalledAsset = true
                switch try await primaryInstalledDocumentationAssetFallback(
                    requestData: requestData,
                    deadline: deadline
                ) {
                case .success(let fallback):
                    return .handled(
                        fallback.responseData,
                        invalidatedProvider: invalidatedProvider
                    )
                case .unavailable:
                    break
                case .requestFailed(let error):
                    return .failed(error, invalidatedProvider: invalidatedProvider)
                case .candidateFailed(let error):
                    lastCandidateFailure = error
                }
            }
            if let activeProvider,
                rejectedProcessIDs.contains(activeProvider.profile.target.processID) == false,
                activeProviderIsCurrentBest(
                    activeProvider,
                    excluding: rejectedProcessIDs
                )
            {
                let fallbackTargets = orderedTargets(
                    excluding: rejectedProcessIDs
                        .union([activeProvider.profile.target.processID])
                )
                let activeDeadline = makeDeadline(
                    fromTimeout: timeoutForCandidate(
                        until: deadline,
                        remainingCandidateCount: fallbackTargets.count + 1
                    )
                )
                let activeProfile: CandidateProfile
                do {
                    activeProfile = try await preparedProvider(
                        for: activeProvider.profile.target,
                        requestTimeout: remainingTimeout(until: activeDeadline),
                        fetchDescriptor: true
                    )
                } catch {
                    rejectedProcessIDs.insert(activeProvider.profile.target.processID)
                    invalidatedProvider = true
                    lastCandidateFailure = error
                    await invalidate(activeProvider, reason: "active_documentation_provider_unprepared")
                    continue
                }
                guard profileCanHandleDocumentationSearch(activeProfile) else {
                    rejectedProcessIDs.insert(activeProvider.profile.target.processID)
                    invalidatedProvider = true
                    await invalidate(activeProvider, reason: "active_documentation_provider_missing_descriptor")
                    continue
                }
                switch try await attemptDocumentationSearch(
                    requestData: requestData,
                    provider: ActiveProvider(profile: activeProfile),
                    deadline: activeDeadline
                ) {
                case .success(let data, let replacementProfile):
                    if let replacementProfile {
                        await cacheInstalledDocumentationAssetReplacement(
                            replacementProfile,
                            replacing: activeProvider.profile
                        )
                        invalidatedProvider = true
                    }
                    return .handled(data, invalidatedProvider: invalidatedProvider)
                case .rejected(let processID, let permanentlyUnusable):
                    rememberRejectedProvider(
                        processID: processID,
                        permanentlyUnusable: permanentlyUnusable,
                        rejectedProcessIDs: &rejectedProcessIDs
                    )
                    invalidatedProvider = true
                    continue
                case .requestFailed(let error):
                    return .failed(error, invalidatedProvider: invalidatedProvider)
                case .candidateFailed(let error):
                    rejectedProcessIDs.insert(activeProvider.profile.target.processID)
                    lastCandidateFailure = error
                    continue
                case .failed(let error):
                    if let deadline, deadline.hasExpired {
                        return .failed(error, invalidatedProvider: invalidatedProvider)
                    }
                    rejectedProcessIDs.insert(activeProvider.profile.target.processID)
                    invalidatedProvider = true
                    continue
                }
            }

            let targets = orderedTargets(
                excluding: rejectedProcessIDs
            )
            guard targets.isEmpty == false else {
                try Task.checkCancellation()
                if let deadline, deadline.hasExpired {
                    return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
                }
                if let lastCandidateFailure {
                    return .failed(lastCandidateFailure, invalidatedProvider: invalidatedProvider)
                }
                return .unavailable(.noAvailableProvider)
            }

            var progressed = false
            for (index, target) in targets.enumerated() {
                let hasRemainingCandidate = index + 1 < targets.count
                if let deadline, deadline.hasExpired {
                    return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
                }
                let candidateDeadline = makeDeadline(
                    fromTimeout: timeoutForCandidate(
                        until: deadline,
                        remainingCandidateCount: targets.count - index
                    )
                )
                do {
                    let profile = try await preparedProvider(
                        for: target,
                        requestTimeout: remainingTimeout(until: candidateDeadline),
                        fetchDescriptor: true
                    )
                    guard profileCanHandleDocumentationSearch(profile) else {
                        logger.info(
                            "Documentation provider candidate cannot handle DocumentationSearch; trying next candidate",
                            metadata: [
                                "pid": .string("\(target.processID)"),
                                "app_path": .string(target.appPath),
                                "xcode_version": .string(target.xcodeVersion),
                            ]
                        )
                        rememberRejectedProvider(
                            processID: target.processID,
                            permanentlyUnusable: true,
                            rejectedProcessIDs: &rejectedProcessIDs
                        )
                        progressed = true
                        await discardPreparedProvider(profile)
                        continue
                    }
                    let provider = ActiveProvider(profile: profile)
                    switch try await attemptDocumentationSearch(
                        requestData: requestData,
                        provider: provider,
                        deadline: candidateDeadline
                    ) {
                    case .success(let data, let replacementProfile):
                        let selectedProfile = replacementProfile ?? profile
                        if let replacementProfile {
                            await cacheInstalledDocumentationAssetReplacement(
                                replacementProfile,
                                replacing: profile
                            )
                            invalidatedProvider = true
                        }
                        let didPromote = await promoteToActive(selectedProfile)
                        if didPromote {
                            logger.info(
                                "Selected documentation provider",
                                metadata: [
                                    "pid": .string("\(target.processID)"),
                                    "app_path": .string(target.appPath),
                                    "xcode_version": .string(target.xcodeVersion),
                                    "server_version": .string(profile.serverVersion),
                                ]
                            )
                        }
                        return .handled(data, invalidatedProvider: invalidatedProvider)
                    case .rejected(let processID, let permanentlyUnusable):
                        rememberRejectedProvider(
                            processID: processID,
                            permanentlyUnusable: permanentlyUnusable,
                            rejectedProcessIDs: &rejectedProcessIDs
                        )
                        invalidatedProvider = true
                        progressed = true
                        await discardPreparedProvider(processID: processID)
                        continue
                    case .requestFailed(let error):
                        return .failed(error, invalidatedProvider: invalidatedProvider)
                    case .candidateFailed(let error):
                        rejectedProcessIDs.insert(target.processID)
                        lastCandidateFailure = error
                        progressed = true
                        if hasRemainingCandidate {
                            await discardPreparedProvider(processID: target.processID)
                        }
                        continue
                    case .failed(let error):
                        rejectedProcessIDs.insert(target.processID)
                        invalidatedProvider = true
                        progressed = true
                        await discardPreparedProvider(processID: target.processID)
                        if let deadline, deadline.hasExpired {
                            return .failed(error, invalidatedProvider: invalidatedProvider)
                        }
                        continue
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    rejectedProcessIDs.insert(target.processID)
                    invalidatedProvider = true
                    progressed = true
                    if hasRemainingCandidate {
                        await discardPreparedProvider(processID: target.processID)
                    }
                    if let deadline, deadline.hasExpired {
                        return .failed(error, invalidatedProvider: invalidatedProvider)
                    }
                    logger.debug(
                        "Documentation provider candidate rejected before user request",
                        metadata: candidateLogMetadata(target: target, error: error)
                    )
                }
            }
            if !progressed {
                return .unavailable(.noAvailableProvider)
            }
        }
        throw CancellationError()
    }

    private func activeProviderIsCurrentBest(
        _ activeProvider: ActiveProvider,
        excluding excludedProcessIDs: Set<pid_t>
    ) -> Bool {
        guard let first = orderedTargets(excluding: excludedProcessIDs).first else {
            return false
        }
        return first.processID == activeProvider.profile.target.processID
    }

    private func profileCanHandleDocumentationSearch(_ profile: CandidateProfile) -> Bool {
        profile.descriptor != nil
    }

    private func promoteToActive(_ profile: CandidateProfile) async -> Bool {
        let previous = activeProvider
        activeProvider = ActiveProvider(profile: profile)
        preparedProviders.removeValue(forKey: profile.target.processID)
        guard let previous else {
            return true
        }
        guard previous.profile.id != profile.id else {
            return false
        }
        await closeTransportRouteIfPresent(previous.profile, awaitTermination: isShutdown)
        return true
    }

    private func rememberRejectedProvider(
        processID: pid_t,
        permanentlyUnusable: Bool,
        rejectedProcessIDs: inout Set<pid_t>
    ) {
        rejectedProcessIDs.insert(processID)
        if permanentlyUnusable {
            permanentlyUnusableProcessIDs.insert(processID)
        }
    }

    private enum DocumentationAttemptResult: Sendable {
        case success(data: Data, replacementProfile: CandidateProfile?)
        case rejected(processID: pid_t, permanentlyUnusable: Bool)
        case requestFailed(any Error)
        case candidateFailed(any Error)
        case failed(any Error)
    }

    private enum InstalledDocumentationAssetFallbackAttempt: Sendable {
        case success(InstalledDocumentationAssetFallback)
        case unavailable
        case requestFailed(any Error)
        case candidateFailed(any Error)
    }

    private enum InstalledDocumentationAssetFailureScope {
        case request
        case candidate
        case provider
    }

    private func attemptDocumentationSearch(
        requestData: Data,
        provider: ActiveProvider,
        deadline: Deadline?
    ) async throws -> DocumentationAttemptResult {
        let processID = provider.profile.target.processID
        if provider.profile.backend.usesInstalledDocumentationAsset {
            do {
                let response = try await localSearchProvider.callDocumentationSearch(
                    requestData: requestData,
                    for: provider.profile.target,
                    timeout: remainingTimeout(until: deadline)
                )
                return .success(data: response, replacementProfile: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch installedDocumentationAssetFailureScope(error) {
                case .request:
                    return .requestFailed(error)
                case .candidate:
                    return .candidateFailed(error)
                case .provider:
                    break
                }
                await invalidate(provider, reason: "installed_documentation_asset_call_failed")
                return .rejected(processID: processID, permanentlyUnusable: true)
            }
        }
        guard let route = provider.profile.route else {
            return .rejected(processID: processID, permanentlyUnusable: true)
        }
        do {
            let response = try await transport.callDocumentationSearch(
                route: route,
                requestData: requestData,
                timeout: remainingTimeout(until: deadline)
            )
            guard !DocumentationProvider.ToolCatalog.responseIsDocumentationNotEnabled(response)
            else {
                if let fallbackResult = try await documentationAttemptResultFromInstalledDocumentationAssetFallback(
                    requestData: requestData,
                    provider: provider.profile,
                    deadline: deadline
                ) {
                    return fallbackResult
                }
                await invalidate(provider, reason: "documentation_search_tool_error")
                return .rejected(processID: processID, permanentlyUnusable: true)
            }
            if DocumentationProvider.ToolCatalog.responseIsDocumentationProviderFailure(response) {
                if let fallbackResult = try await documentationAttemptResultFromInstalledDocumentationAssetFallback(
                    requestData: requestData,
                    provider: provider.profile,
                    deadline: deadline
                ) {
                    return fallbackResult
                }
                await invalidate(provider, reason: "documentation_search_provider_failure")
                return .rejected(processID: processID, permanentlyUnusable: false)
            }
            return .success(data: response, replacementProfile: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let fallbackResult = try await documentationAttemptResultFromInstalledDocumentationAssetFallback(
                requestData: requestData,
                provider: provider.profile,
                deadline: deadline
            ) {
                return fallbackResult
            }
            await invalidate(provider, reason: "documentation_provider_call_failed")
            return .failed(error)
        }
    }

    private func installedDocumentationAssetFailureScope(_ error: any Error)
        -> InstalledDocumentationAssetFailureScope
    {
        if error is TimeoutError {
            return .candidate
        }
        if let controlPlaneError = error as? ControlPlane.Error {
            switch controlPlaneError {
            case .invalidResponse(let message):
                if message == "missing DocumentationSearch request id"
                    || message == "missing DocumentationSearch query"
                {
                    return .request
                }
                return .provider
            case .upstreamRPC:
                return .request
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return .request
        }
        return .provider
    }

    private func documentationAttemptResultFromInstalledDocumentationAssetFallback(
        requestData: Data,
        provider: CandidateProfile,
        deadline: Deadline?
    ) async throws -> DocumentationAttemptResult? {
        switch try await attemptInstalledDocumentationAssetFallback(
            requestData: requestData,
            target: provider.target,
            deadline: deadline
        ) {
        case .success(let fallback):
            return .success(
                data: fallback.responseData,
                replacementProfile: await profileByUsingInstalledDocumentationAssetFallback(
                    provider,
                    fallback: fallback
                )
            )
        case .unavailable:
            return nil
        case .requestFailed(let error):
            return .requestFailed(error)
        case .candidateFailed(let error):
            return .candidateFailed(error)
        }
    }

    private func attemptInstalledDocumentationAssetFallback(
        requestData: Data,
        target: XcodeProcessTarget,
        deadline: Deadline?,
        isPrimaryAttempt: Bool = false
    ) async throws -> InstalledDocumentationAssetFallbackAttempt {
        do {
            guard let fallback = try await callInstalledDocumentationAssetFallback(
                requestData: requestData,
                target: target,
                deadline: deadline,
                isPrimaryAttempt: isPrimaryAttempt
            ) else {
                return .unavailable
            }
            return .success(fallback)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug(
                "Installed documentation asset fallback failed",
                metadata: candidateLogMetadata(target: target, error: error)
            )
            switch installedDocumentationAssetFailureScope(error) {
            case .request:
                return .requestFailed(error)
            case .candidate:
                return .candidateFailed(error)
            case .provider:
                return .unavailable
            }
        }
    }

    private func primaryInstalledDocumentationAssetFallback(
        requestData: Data,
        deadline: Deadline?
    ) async throws -> InstalledDocumentationAssetFallbackAttempt {
        try await attemptInstalledDocumentationAssetFallback(
            requestData: requestData,
            target: Self.installedDocumentationAssetStandaloneTarget,
            deadline: deadline,
            isPrimaryAttempt: true
        )
    }

    private func installedDocumentationAssetToolListUpdate() async
        -> DocumentationProvider.ToolListUpdate
    {
        if let descriptor = await localSearchProvider.descriptor(
            for: Self.installedDocumentationAssetStandaloneTarget
        ) {
            return .available(descriptor)
        }
        for target in orderedTargetsForInstalledDocumentationAssetFallback() {
            if let descriptor = await localSearchProvider.descriptor(for: target) {
                return .available(descriptor)
            }
        }
        return .unavailable
    }

    func invalidate(reason: String) async {
        await invalidate(reason: reason, awaitRouteTermination: false)
    }

    private func invalidate(reason _: String, awaitRouteTermination: Bool) async {
        let preparations = providerPreparations
        providerPreparations.removeAll()
        for preparation in preparations.values {
            preparation.task.cancel()
        }
        let prepared = preparedProviders
        preparedProviders.removeAll()
        let provider = activeProvider
        activeProvider = nil
        permanentlyUnusableProcessIDs.removeAll()
        for profile in prepared.values where profile.id != provider?.profile.id {
            await closeTransportRouteIfPresent(
                profile,
                awaitTermination: awaitRouteTermination
            )
        }
        if let provider {
            await closeTransportRouteIfPresent(
                provider.profile,
                awaitTermination: awaitRouteTermination
            )
        }
    }

    private func discardPreparedProvider(processID: pid_t) async {
        providerPreparations.removeValue(forKey: processID)?.task.cancel()
        guard let profile = preparedProviders.removeValue(forKey: processID) else {
            return
        }
        guard activeProvider?.profile.id != profile.id else {
            return
        }
        await closeTransportRouteIfPresent(profile, awaitTermination: isShutdown)
    }

    private func discardPreparedProvider(_ profile: CandidateProfile) async {
        providerPreparations.removeValue(forKey: profile.target.processID)?.task.cancel()
        let cached = preparedProviders.removeValue(forKey: profile.target.processID)
        if let cached, cached.id != profile.id,
           activeProvider?.profile.id != cached.id
        {
            await closeTransportRouteIfPresent(cached, awaitTermination: isShutdown)
        }
        guard activeProvider?.profile.id != profile.id else {
            return
        }
        await closeTransportRouteIfPresent(profile, awaitTermination: isShutdown)
    }

    private func closeTransportRouteIfPresent(
        _ profile: CandidateProfile,
        awaitTermination: Bool = false
    ) async {
        guard let route = profile.route else {
            return
        }
        if awaitTermination {
            await transport.closeForShutdown(route: route)
        } else {
            await transport.close(route: route)
        }
    }

    private func cacheInstalledDocumentationAssetReplacement(
        _ replacementProfile: CandidateProfile,
        replacing replacedProfile: CandidateProfile
    ) async {
        providerPreparations.removeValue(forKey: replacedProfile.target.processID)?.task.cancel()
        if let activeProvider, activeProvider.profile.id == replacedProfile.id {
            self.activeProvider = ActiveProvider(profile: replacementProfile)
        }
        if let prepared = preparedProviders[replacedProfile.target.processID],
           prepared.id == replacedProfile.id
        {
            preparedProviders[replacedProfile.target.processID] = replacementProfile
        }
    }

    func shutdown() async {
        lifecycle.markShutdown()
        isShutdown = true
        await invalidate(reason: "shutdown", awaitRouteTermination: true)
        await transport.shutdown()
    }

    private func preparedProvider(
        for target: XcodeProcessTarget,
        requestTimeout: TimeAmount?,
        fetchDescriptor: Bool
    ) async throws -> CandidateProfile {
        if let activeProvider, activeProvider.profile.target.processID == target.processID {
            if fetchDescriptor,
               activeProvider.profile.descriptor == nil,
               activeProvider.profile.descriptorLookupCompleted == false
            {
                let updated = await profileByRefreshingDescriptorWithRepair(
                    activeProvider.profile,
                    requestTimeout: requestTimeout
                )
                if let current = self.activeProvider,
                    current.profile.id == updated.id
                {
                    let merged = profileByPreferringDescriptor(
                        primary: current.profile,
                        fallback: updated
                    )
                    self.activeProvider = ActiveProvider(profile: merged)
                    return merged
                }
                if let current = self.activeProvider,
                   current.profile.id == activeProvider.profile.id
                {
                    self.activeProvider = ActiveProvider(profile: updated)
                    return updated
                }
                return updated
            }
            return activeProvider.profile
        }
        if var prepared = preparedProviders[target.processID] {
            if fetchDescriptor,
               prepared.descriptor == nil,
               prepared.descriptorLookupCompleted == false
            {
                let updated = await profileByRefreshingDescriptorWithRepair(
                    prepared,
                    requestTimeout: requestTimeout
                )
                if let activeProvider, activeProvider.profile.id == updated.id {
                    let merged = profileByPreferringDescriptor(
                        primary: activeProvider.profile,
                        fallback: updated
                    )
                    self.activeProvider = ActiveProvider(profile: merged)
                    return merged
                }
                if let cached = preparedProviders[target.processID],
                    cached.id == updated.id
                {
                    let merged = profileByPreferringDescriptor(
                        primary: cached,
                        fallback: updated
                    )
                    preparedProviders[target.processID] = merged
                    return merged
                }
                prepared = updated
                preparedProviders[target.processID] = prepared
            }
            return prepared
        }
        let preparation: ProviderPreparation
        if let existing = providerPreparations[target.processID] {
            preparation = existing
            testHooks.providerPreparationReused(target.processID)
        } else {
            let timeout = providerSelectionTimeout
            let context = ProviderPreparationContext(
                transport: transport,
                initializeParams: initializeParams,
                localSearchProvider: localSearchProvider,
                preferLocalSearchProvider: preferLocalSearchProvider,
                clock: clock,
                logger: logger,
                lifecycle: lifecycle
            )
            preparation = ProviderPreparation(
                task: Task {
                    try await context.openProviderRoute(
                        target: target,
                        requestTimeout: timeout
                    )
                }
            )
            providerPreparations[target.processID] = preparation
        }
        let profile: CandidateProfile
        do {
            profile = try await waitForPreparation(preparation, requestTimeout: requestTimeout)
        } catch is PreparationWaitTimedOut {
            testHooks.providerPreparationWaitTimedOut(target.processID)
            throw TimeoutError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            providerPreparations.removeValue(forKey: target.processID)
            throw error
        }
        providerPreparations.removeValue(forKey: target.processID)
        if isShutdown {
            await closeTransportRouteIfPresent(profile, awaitTermination: true)
            throw CancellationError()
        }
        return try await cachePreparedProvider(
            profile,
            requestTimeout: requestTimeout,
            fetchDescriptor: fetchDescriptor
        )
    }

    private func cachePreparedProvider(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?,
        fetchDescriptor: Bool
    ) async throws -> CandidateProfile {
        if let activeProvider, activeProvider.profile.id == profile.id {
            if fetchDescriptor,
               activeProvider.profile.descriptor == nil,
               activeProvider.profile.descriptorLookupCompleted == false
            {
                let updated = await profileByRefreshingDescriptorWithRepair(
                    activeProvider.profile,
                    requestTimeout: requestTimeout
                )
                self.activeProvider = ActiveProvider(profile: updated)
                return updated
            }
            return activeProvider.profile
        }
        if let prepared = preparedProviders[profile.target.processID],
            prepared.id == profile.id
        {
            if fetchDescriptor,
               prepared.descriptor == nil,
               prepared.descriptorLookupCompleted == false
            {
                let updated = await profileByRefreshingDescriptorWithRepair(
                    prepared,
                    requestTimeout: requestTimeout
                )
                preparedProviders[profile.target.processID] = updated
                return updated
            }
            return prepared
        }

        var prepared = profile
        preparedProviders[profile.target.processID] = prepared
        if fetchDescriptor,
           prepared.descriptor == nil,
           prepared.descriptorLookupCompleted == false
        {
            prepared = await profileByRefreshingDescriptorWithRepair(
                prepared,
                requestTimeout: requestTimeout
            )
            if let activeProvider, activeProvider.profile.id == profile.id {
                let merged = profileByPreferringDescriptor(
                    primary: activeProvider.profile,
                    fallback: prepared
                )
                self.activeProvider = ActiveProvider(profile: merged)
                return merged
            }
            if let cached = preparedProviders[profile.target.processID],
                cached.id == profile.id
            {
                let merged = profileByPreferringDescriptor(primary: cached, fallback: prepared)
                preparedProviders[profile.target.processID] = merged
                return merged
            }
        }

        if let cached = preparedProviders[profile.target.processID],
            cached.id == profile.id
        {
            let merged = profileByPreferringDescriptor(primary: cached, fallback: prepared)
            preparedProviders[profile.target.processID] = merged
            return merged
        }
        preparedProviders[profile.target.processID] = prepared
        return prepared
    }

    private func profileByPreferringDescriptor(
        primary: CandidateProfile,
        fallback: CandidateProfile
    ) -> CandidateProfile {
        guard primary.id == fallback.id else {
            return fallback
        }
        guard primary.descriptor == nil, fallback.descriptor != nil else {
            var merged = primary
            if fallback.descriptorLookupCompleted {
                merged.descriptorLookupCompleted = true
            }
            return merged
        }
        return fallback
    }

    private func waitForPreparation(
        _ preparation: ProviderPreparation,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        guard let requestTimeout else {
            return try await preparation.task.value
        }
        guard requestTimeout.nanoseconds > 0 else {
            throw PreparationWaitTimedOut()
        }
        let waiter = PreparationWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.setContinuation(continuation)
                waiter.addTask(Task {
                    do {
                        let profile = try await preparation.task.value
                        waiter.resume(.success(profile))
                    } catch {
                        waiter.resume(.failure(error))
                    }
                })
                let clock = clock
                waiter.addTask(Task {
                    await clock.sleep(.nanoseconds(requestTimeout.nanoseconds))
                    guard Task.isCancelled == false else {
                        return
                    }
                    waiter.resume(.failure(PreparationWaitTimedOut()))
                })
            }
        } onCancel: {
            waiter.resume(.failure(CancellationError()))
        }
    }

    private func invalidate(_ provider: ActiveProvider, reason _: String) async {
        if let prepared = preparedProviders[provider.profile.target.processID],
            prepared.id == provider.profile.id
        {
            preparedProviders.removeValue(forKey: provider.profile.target.processID)
        }
        if let activeProvider, activeProvider.profile.id == provider.profile.id {
            self.activeProvider = nil
        }
        await closeTransportRouteIfPresent(provider.profile, awaitTermination: isShutdown)
    }

    private func orderedTargets(
        excluding excludedProcessIDs: Set<pid_t>
    ) -> [XcodeProcessTarget] {
        let excludedProcessIDs = excludedProcessIDs.union(permanentlyUnusableProcessIDs)
        let filtered = discovery.runningXcodeTargets().filter {
            excludedProcessIDs.contains($0.processID) == false
        }
        return sortedDocumentationTargets(filtered)
    }

    private func orderedTargetsForInstalledDocumentationAssetFallback()
        -> [XcodeProcessTarget]
    {
        sortedDocumentationTargets(discovery.runningXcodeTargets())
    }

    private func sortedDocumentationTargets(
        _ targets: [XcodeProcessTarget]
    ) -> [XcodeProcessTarget] {
        // DocumentationSearch owns provider selection separately from workspace/tab routing.
        // Discovery order is only target enumeration; version and stable identity choose priority.
        targets.sorted { lhs, rhs in
            let versionComparison = Self.compareVersion(lhs.xcodeVersion, rhs.xcodeVersion)
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }
            if lhs.appPath != rhs.appPath {
                return lhs.appPath < rhs.appPath
            }
            return lhs.processID < rhs.processID
        }
    }

    private func openProviderRoute(
        target: XcodeProcessTarget,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        guard !isShutdown else {
            throw CancellationError()
        }
        logger.debug(
            "Preparing documentation provider candidate",
            metadata: [
                "pid": .string("\(target.processID)"),
                "app_path": .string(target.appPath),
                "xcode_version": .string(target.xcodeVersion),
            ]
        )
        let startupDeadline = Deadline.fromNow(requestTimeout ?? .seconds(30), clock: clock)
        try Task.checkCancellation()
        let startupTimeout = remainingTimeout(until: startupDeadline)
        guard startupTimeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        let route: DocumentationProviderRoute
        do {
            route = try await transport.openRoute(
                for: target,
                requestTimeout: startupTimeout,
                initializeParams: initializeParams
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let localProfile = await installedDocumentationAssetPrimaryProfile(for: target) {
                return localProfile
            }
            throw error
        }
        do {
            try Task.checkCancellation()
            guard !isShutdown else {
                throw CancellationError()
            }
            guard remainingTimeout(until: startupDeadline)?.nanoseconds != 0 else {
                throw TimeoutError()
            }
        } catch {
            if isShutdown {
                await transport.closeForShutdown(route: route)
            } else {
                await transport.close(route: route)
            }
            throw error
        }
        return CandidateProfile(
            id: UUID(),
            target: target,
            backend: .xcode(route: route, descriptor: nil),
            serverVersion: route.serverVersion,
            descriptorLookupCompleted: false
        )
    }

    private func installedDocumentationAssetPrimaryProfile(
        for target: XcodeProcessTarget
    ) async -> CandidateProfile? {
        guard let descriptor = await localSearchProvider.descriptor(for: target) else {
            return nil
        }
        logger.info(
            "Using installed documentation asset as primary DocumentationSearch provider",
            metadata: [
                "pid": .string("\(target.processID)"),
                "app_path": .string(target.appPath),
                "xcode_version": .string(target.xcodeVersion),
            ]
        )
        return CandidateProfile(
            id: UUID(),
            target: target,
            backend: .installedDocumentationAsset(descriptor: descriptor),
            serverVersion: "installed-documentation-asset",
            descriptorLookupCompleted: true
        )
    }

    private func profileWithDescriptor(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?
    ) async throws -> CandidateProfile {
        var updated = profile
        let toolsListTimeout = requestTimeout
        guard toolsListTimeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        guard let route = profile.route else {
            return profile
        }
        let toolsResult = try await transport.toolsList(
            route: route,
            timeout: toolsListTimeout
        )
        updated.backend = .xcode(
            route: route,
            descriptor: DocumentationProvider.ToolCatalog.descriptor(in: toolsResult)
        )
        updated.descriptorLookupCompleted = true
        return updated
    }

    private func profileByRefreshingDescriptorWithRepair(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?
    ) async -> CandidateProfile {
        guard requestTimeout?.nanoseconds != 0 else {
            return profile
        }
        let deadline = Deadline.fromNow(requestTimeout, clock: clock)
        let refreshed = await profileByRefreshingDescriptor(
            profile,
            requestTimeout: remainingTimeout(until: deadline)
        )
        guard refreshed.descriptor == nil else {
            return refreshed
        }
        guard remainingTimeout(until: deadline)?.nanoseconds != 0 else {
            return refreshed
        }
        let repaired = await profileByRepairingDocumentationSearchService(
            refreshed,
            requestTimeout: remainingTimeout(until: deadline)
        )
        guard repaired.descriptor == nil else {
            return repaired
        }
        return await profileByAddingInstalledDocumentationAssetFallback(repaired)
    }

    private func profileByRepairingDocumentationSearchService(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?
    ) async -> CandidateProfile {
        guard requestTimeout?.nanoseconds != 0, !Task.isCancelled, !isShutdown else {
            return profile
        }
        guard reserveServiceRepairAttempt(for: profile.target.processID) else {
            return profile
        }

        logger.warning(
            "DocumentationSearch descriptor missing; attempting Xcode documentation service repair",
            metadata: [
                "pid": .string("\(profile.target.processID)"),
                "app_path": .string(profile.target.appPath),
                "xcode_version": .string(profile.target.xcodeVersion),
            ]
        )

        let deadline = Deadline.fromNow(requestTimeout, clock: clock)
        guard let repairResult = await repairDocumentationSearch(
            for: profile.target,
            timeout: remainingTimeout(until: deadline)
        ) else {
            serviceRepairAttemptedProcessIDs.remove(profile.target.processID)
            logger.debug(
                "Xcode documentation service repair did not finish before timeout",
                metadata: [
                    "pid": .string("\(profile.target.processID)"),
                    "app_path": .string(profile.target.appPath),
                    "xcode_version": .string(profile.target.xcodeVersion),
                ]
            )
            return profile
        }
        switch repairResult {
        case .repaired(let report):
            logger.info(
                "Repaired Xcode documentation service configuration",
                metadata: [
                    "pid": .string("\(profile.target.processID)"),
                    "config_url": .string(report.configURL),
                    "asset_xcode_version": .string(report.xcodeVersion),
                    "asset_os_version": .string(report.osVersion),
                    "documentation_release": .string(
                        report.documentationRelease.map(String.init) ?? "unknown"
                    ),
                    "changed_default": .string("\(report.changedDefault)"),
                ]
            )
        case .skipped(let reason):
            logger.info(
                "Skipped Xcode documentation service repair",
                metadata: [
                    "pid": .string("\(profile.target.processID)"),
                    "reason": .string(reason),
                ]
            )
            return profile
        case .failed(let reason):
            logger.warning(
                "Xcode documentation service repair failed",
                metadata: [
                    "pid": .string("\(profile.target.processID)"),
                    "reason": .string(reason),
                ]
            )
            return profile
        }
        guard remainingTimeout(until: deadline)?.nanoseconds != 0 else {
            return profile
        }

        do {
            let replacement = try await openProviderRoute(
                target: profile.target,
                requestTimeout: remainingTimeout(until: deadline)
            )
            if replacement.route?.id != profile.route?.id {
                await closeTransportRouteIfPresent(profile, awaitTermination: isShutdown)
            }
            let updated = await profileByRefreshingDescriptor(
                replacement,
                requestTimeout: remainingTimeout(until: deadline)
            )
            if updated.descriptor == nil {
                logger.warning(
                    "Xcode documentation service repair did not restore DocumentationSearch",
                    metadata: [
                        "pid": .string("\(profile.target.processID)"),
                        "app_path": .string(profile.target.appPath),
                        "xcode_version": .string(profile.target.xcodeVersion),
                    ]
                )
            } else {
                logger.info(
                    "Xcode documentation service repair restored DocumentationSearch",
                    metadata: [
                        "pid": .string("\(profile.target.processID)"),
                        "app_path": .string(profile.target.appPath),
                        "xcode_version": .string(profile.target.xcodeVersion),
                    ]
                )
            }
            return updated
        } catch is CancellationError {
            return profile
        } catch {
            logger.warning(
                "Xcode documentation service repair could not reopen provider route",
                metadata: candidateLogMetadata(target: profile.target, error: error)
            )
            return await profileByAddingInstalledDocumentationAssetFallback(profile)
        }
    }

    private func profileByAddingInstalledDocumentationAssetFallback(
        _ profile: CandidateProfile
    ) async -> CandidateProfile {
        guard let descriptor = await localSearchProvider.descriptor(for: profile.target) else {
            return profile
        }
        logger.warning(
            "Using installed documentation asset fallback for DocumentationSearch",
            metadata: [
                "pid": .string("\(profile.target.processID)"),
                "app_path": .string(profile.target.appPath),
                "xcode_version": .string(profile.target.xcodeVersion),
            ]
        )
        var updated = profile
        updated.backend = .installedDocumentationAsset(descriptor: descriptor)
        updated.descriptorLookupCompleted = true
        await closeTransportRouteIfPresent(profile, awaitTermination: isShutdown)
        return updated
    }

    private func profileByUsingInstalledDocumentationAssetFallback(
        _ profile: CandidateProfile,
        fallback: InstalledDocumentationAssetFallback
    ) async -> CandidateProfile {
        var updated = profile
        updated.backend = .installedDocumentationAsset(descriptor: fallback.descriptor)
        updated.descriptorLookupCompleted = true
        await closeTransportRouteIfPresent(profile, awaitTermination: isShutdown)
        return updated
    }

    private func repairDocumentationSearch(
        for target: XcodeProcessTarget,
        timeout: TimeAmount?
    ) async -> DocumentationSearchServiceRepairResult? {
        guard timeout?.nanoseconds != 0 else {
            return nil
        }
        guard let timeout, timeout.nanoseconds > 0 else {
            return await serviceRepairer.repairDocumentationSearch(for: target)
        }
        let result = await DocumentationSearchServiceRepairWaiter().wait(
            for: Task {
                await serviceRepairer.repairDocumentationSearch(for: target)
            },
            timeout: timeout,
            clock: clock
        )
        return result.repairResult
    }

    private func callInstalledDocumentationAssetFallback(
        requestData: Data,
        target: XcodeProcessTarget,
        deadline: Deadline?,
        isPrimaryAttempt: Bool
    ) async throws -> InstalledDocumentationAssetFallback? {
        guard let descriptor = await localSearchProvider.descriptor(for: target) else {
            return nil
        }
        let metadata: Logger.Metadata = [
            "pid": .string("\(target.processID)"),
            "app_path": .string(target.appPath),
            "xcode_version": .string(target.xcodeVersion),
        ]
        if isPrimaryAttempt {
            logger.info(
                "Using installed documentation asset as primary DocumentationSearch provider",
                metadata: metadata
            )
        } else {
            logger.warning(
                "Falling back to installed documentation asset for DocumentationSearch",
                metadata: metadata
            )
        }
        let responseData = try await localSearchProvider.callDocumentationSearch(
            requestData: requestData,
            for: target,
            timeout: remainingTimeout(until: deadline)
        )
        return InstalledDocumentationAssetFallback(responseData: responseData, descriptor: descriptor)
    }

    private func reserveServiceRepairAttempt(for processID: pid_t) -> Bool {
        guard serviceRepairAttemptedProcessIDs.contains(processID) == false else {
            return false
        }
        serviceRepairAttemptedProcessIDs.insert(processID)
        return true
    }

    private func profileByRefreshingDescriptor(
        _ profile: CandidateProfile,
        requestTimeout: TimeAmount?
    ) async -> CandidateProfile {
        let deadline = Deadline.fromNow(requestTimeout, clock: clock)
        let maxAttempts = maxDescriptorRefreshAttempts(for: requestTimeout)
        var attempt = 0
        while !Task.isCancelled {
            do {
                let updated = try await profileWithDescriptor(
                    profile,
                    requestTimeout: remainingTimeout(until: deadline)
                )
                if updated.descriptor == nil {
                    logger.info(
                        "DocumentationSearch descriptor missing from Xcode tools/list",
                        metadata: [
                            "pid": .string("\(profile.target.processID)"),
                            "app_path": .string(profile.target.appPath),
                            "xcode_version": .string(profile.target.xcodeVersion),
                        ]
                    )
                }
                return updated
            } catch is CancellationError {
                return profile
            } catch {
                logger.debug(
                    "Documentation provider descriptor refresh failed",
                    metadata: candidateLogMetadata(target: profile.target, error: error)
                )
                guard descriptorRefreshErrorIsRetryable(error),
                      attempt < maxAttempts,
                      remainingTimeout(until: deadline)?.nanoseconds != 0 else {
                    return profile
                }
                attempt += 1
                await sleepBeforeRetryingDescriptorRefresh(until: deadline)
            }
        }
        return profile
    }

    private func descriptorRefreshErrorIsRetryable(_ error: any Error) -> Bool {
        if error is UpstreamSlotScheduler.AcquisitionError {
            return true
        }
        return false
    }

    private func maxDescriptorRefreshAttempts(for requestTimeout: TimeAmount?) -> Int {
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return 120
        }
        let attempts = (requestTimeout.nanoseconds + descriptorRefreshRetryDelayNanoseconds - 1)
            / descriptorRefreshRetryDelayNanoseconds
        return max(1, min(120, Int(attempts)))
    }

    private func sleepBeforeRetryingDescriptorRefresh(until deadline: Deadline?) async {
        guard let remaining = remainingTimeout(until: deadline),
              remaining.nanoseconds > 0 else {
            return
        }
        await clock.sleep(
            .nanoseconds(min(remaining.nanoseconds, descriptorRefreshRetryDelayNanoseconds))
        )
    }

    static func resultValue(from responseData: Data) throws -> JSONValue {
        guard
            let object = try JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"],
            let value = JSONValue(any: result)
        else {
            throw ControlPlane.Error.invalidResponse("invalid documentation provider response")
        }
        return value
    }

    static func serverVersion(fromInitializeResponse data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let result = object["result"] as? [String: Any],
            let serverInfo = result["serverInfo"] as? [String: Any]
        else {
            return nil
        }
        return serverInfo["version"] as? String
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

    private func remainingTimeout(until deadline: Deadline?) -> TimeAmount? {
        guard let deadline else {
            return nil
        }
        return deadline.remaining()
    }

    private func timeoutForCandidate(
        until deadline: Deadline?,
        remainingCandidateCount: Int
    ) -> TimeAmount? {
        guard let remaining = remainingTimeout(until: deadline) else {
            return .nanoseconds(candidateAttemptTimeoutNanoseconds)
        }
        guard remaining.nanoseconds > 0 else {
            return .nanoseconds(0)
        }
        guard remainingCandidateCount > 1 else {
            return remaining
        }
        let fairShare = max(1, remaining.nanoseconds / Int64(remainingCandidateCount))
        return .nanoseconds(min(fairShare, candidateAttemptTimeoutNanoseconds))
    }

    private func makeDeadline(fromTimeout timeout: TimeAmount?) -> Deadline? {
        guard let timeout else {
            return nil
        }
        guard timeout.nanoseconds > 0 else {
            return Deadline(uptimeNanoseconds: clock.uptimeNanoseconds(), clock: clock)
        }
        return Deadline.fromNow(timeout, clock: clock)
    }

    private func candidateLogMetadata(
        target: XcodeProcessTarget,
        error: any Error
    ) -> Logger.Metadata {
        [
            "pid": .string("\(target.processID)"),
            "app_path": .string(target.appPath),
            "xcode_version": .string(target.xcodeVersion),
            "error": .string(String(describing: error)),
        ]
    }
}
