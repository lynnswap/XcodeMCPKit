import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP

package enum DocumentationProvider {}

extension DocumentationProvider {
    package enum ToolListUpdate: Sendable {
        case unchanged
        case unavailable
        case available(JSONValue)

        package var debugLabel: String {
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
    package enum UnavailableReason: Sendable, Error, CustomStringConvertible {
        case noAvailableProvider

        package static let userFacingMessage =
            "DocumentationSearch is unavailable from the running Xcode documentation provider. Try restarting Xcode if the problem persists."

        package var message: String {
            switch self {
            case .noAvailableProvider:
                Self.userFacingMessage
            }
        }

        package var description: String {
            message
        }
    }
}

/// The manager's classification of one DocumentationSearch attempt.
/// When the manager is enabled, DocumentationSearch is owned by the
/// documentation provider and does not fall back to the regular upstream.
extension DocumentationProvider {
    package enum CallOutcome: Sendable {
        case handled(Data, invalidatedProvider: Bool)
        case unavailable(DocumentationProvider.UnavailableReason)
        case failed(any Error, invalidatedProvider: Bool)
    }
}

package protocol DocumentationProviderManaging: Sendable {
    func startBackgroundDiscovery(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate
    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome
    func invalidate(reason: String) async
    func shutdown() async
}

package struct DocumentationSearchServiceRepairReport: Sendable, Equatable {
    package let configURL: String
    package let xcodeVersion: String
    package let osVersion: String
    package let documentationRelease: Int?
    package let changedDefault: Bool

    package init(
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

package enum DocumentationSearchServiceRepairResult: Sendable, Equatable {
    case repaired(DocumentationSearchServiceRepairReport)
    case skipped(String)
    case failed(String)
}

package protocol DocumentationSearchServiceRepairing: Sendable {
    func repairDocumentationSearch(
        for target: DocumentationProviderTarget
    ) async -> DocumentationSearchServiceRepairResult
}

package protocol DocumentationSearchProviding: Sendable {
    func descriptor(for target: DocumentationProviderTarget) async -> JSONValue?
    func callDocumentationSearch(
        requestData: Data,
        for target: DocumentationProviderTarget,
        timeout: TimeAmount?
    ) async throws -> Data
}

package struct NoopDocumentationSearchServiceRepairer: DocumentationSearchServiceRepairing {
    package init() {}

    package func repairDocumentationSearch(
        for _: DocumentationProviderTarget
    ) async -> DocumentationSearchServiceRepairResult {
        .skipped("disabled")
    }
}

package struct UnavailableDocumentationSearchProvider: DocumentationSearchProviding {
    package init() {}

    package func descriptor(for _: DocumentationProviderTarget) async -> JSONValue? {
        nil
    }

    package func callDocumentationSearch(
        requestData _: Data,
        for _: DocumentationProviderTarget,
        timeout _: TimeAmount?
    ) async throws -> Data {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }
}

package struct DocumentationProviderRoute: Sendable, Equatable {
    package let id: String
    package let target: DocumentationProviderTarget
    package let upstreamIndex: Int?
    package let serverVersion: String

    package init(
        id: String,
        target: DocumentationProviderTarget,
        upstreamIndex: Int?,
        serverVersion: String = ""
    ) {
        self.id = id
        self.target = target
        self.upstreamIndex = upstreamIndex
        self.serverVersion = serverVersion
    }
}

package protocol DocumentationProviderRouting: Sendable {
    func openRoute(
        for target: DocumentationProviderTarget,
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
    func shutdown() async
}

extension DocumentationProviderRouting {
    package func close(route _: DocumentationProviderRoute) async {}
    package func shutdown() async {}
}

extension DocumentationProvider {
    package enum ToolCatalog {
        package static let toolName = "DocumentationSearch"

        package static func applying(
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

        package static func descriptor(in result: JSONValue) -> JSONValue? {
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

        package static func responseIsDocumentationNotEnabled(_ data: Data) -> Bool {
            responseErrorTexts(in: data).contains { text in
                let normalized = text.lowercased()
                return normalized.contains("documentationsearch")
                    && normalized.contains("not enabled")
            }
        }

        package static func responseIsDocumentationProviderFailure(_ data: Data) -> Bool {
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

package protocol DocumentationProviderSessionMaking: Sendable {
    func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession
}

package struct LiveDocumentationProviderSessionFactory: DocumentationProviderSessionMaking {
    private let baseEnvironment: [String: String]

    package init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    package func startSession(for target: DocumentationProviderTarget) async throws
        -> any UpstreamSession
    {
        var environment = baseEnvironment
        environment.removeValue(forKey: "XCODE_PID")
        environment["MCP_XCODE_PID"] = String(target.processID)
        environment["DEVELOPER_DIR"] = target.developerDir
        let config = UpstreamProcess.Config(
            command: target.mcpbridgePath,
            args: [],
            environment: environment,
            maxQueuedWriteBytes: 4 * 1_048_576
        )
        return try await UpstreamProcess(config: config).startSession()
    }
}

package struct DocumentationSearchInstalledAsset: Sendable, Equatable {
    package let assetURL: URL
    package let configURL: URL
    package let indexURL: URL
    package let xcodeVersion: String
    package let osVersion: String
    package let documentationRelease: Int?

    package init(
        assetURL: URL,
        configURL: URL,
        indexURL: URL,
        xcodeVersion: String,
        osVersion: String,
        documentationRelease: Int?
    ) {
        self.assetURL = assetURL
        self.configURL = configURL
        self.indexURL = indexURL
        self.xcodeVersion = xcodeVersion
        self.osVersion = osVersion
        self.documentationRelease = documentationRelease
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

        return .asset(DocumentationSearchInstalledAsset(
            assetURL: assetURL,
            configURL: configURL,
            indexURL: indexURL,
            xcodeVersion: properties.xcodeVersion,
            osVersion: properties.osVersion,
            documentationRelease: properties.documentationRelease
        ))
    }

    package static func bestAsset(
        for targetXcodeVersion: String,
        currentOSVersion: String,
        from assets: [DocumentationSearchInstalledAsset]
    ) -> DocumentationSearchInstalledAsset? {
        assets.max { lhs, rhs in
            isBetter(rhs, than: lhs, targetXcodeVersion: targetXcodeVersion, currentOSVersion: currentOSVersion)
        }
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
}

package struct LiveDocumentationSearchServiceRepairer: DocumentationSearchServiceRepairing {
    private static let xcodeDefaultsDomain = "com.apple.dt.Xcode"
    private static let configURLDefaultsKey = "IDEChatDocumentationSearchConfigURL"

    private let assetRoot: URL
    private let currentOSVersion: @Sendable () -> String
    private let readConfigURLOverride: @Sendable () -> String?
    private let writeConfigURLOverride: @Sendable (String) -> Bool

    package init(
        assetRoot: URL = DocumentationSearchAssetLocator.defaultAssetRoot,
        currentOSVersion: @escaping @Sendable () -> String =
            DocumentationSearchAssetLocator.currentOperatingSystemVersionString,
        readConfigURLOverride: @escaping @Sendable () -> String? = Self.currentConfigURLOverride,
        writeConfigURLOverride: @escaping @Sendable (String) -> Bool = Self.writeConfigURLOverride
    ) {
        self.assetRoot = assetRoot
        self.currentOSVersion = currentOSVersion
        self.readConfigURLOverride = readConfigURLOverride
        self.writeConfigURLOverride = writeConfigURLOverride
    }

    package func repairDocumentationSearch(
        for target: DocumentationProviderTarget
    ) async -> DocumentationSearchServiceRepairResult {
        let scan: DocumentationSearchAssetScan
        do {
            scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        } catch {
            return .failed("asset_scan_failed: \(error)")
        }
        guard let asset = DocumentationSearchAssetLocator.bestAsset(
            for: target.xcodeVersion,
            currentOSVersion: currentOSVersion(),
            from: scan.assets
        ) else {
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

private final class ProcessOutputTimeoutWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func wait(
        for task: Task<ProcessOutput, Error>,
        timeout: TimeAmount
    ) async throws -> ProcessOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                setContinuation(continuation)
                addTask(Task {
                    do {
                        let output = try await task.value
                        self.resume(.success(output))
                    } catch {
                        self.resume(.failure(error))
                    }
                })
                addTask(Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
                    guard Task.isCancelled == false else {
                        return
                    }
                    task.cancel()
                    self.resume(.failure(TimeoutError()))
                })
            }
        } onCancel: {
            task.cancel()
            resume(.failure(CancellationError()))
        }
    }

    private func setContinuation(_ continuation: CheckedContinuation<ProcessOutput, Error>) {
        lock.lock()
        if resolved {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
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

    private func resume(_ result: Result<ProcessOutput, Error>) {
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
        case .success(let output):
            continuation?.resume(returning: output)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
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
        timeout: TimeAmount
    ) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                setContinuation(continuation)
                addTask(Task {
                    let result = await task.value
                    self.resume(Result(repairResult: result, timedOut: false))
                })
                addTask(Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
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

package struct LiveDocumentationAssetSearchProvider: DocumentationSearchProviding {
    private struct SearchArguments {
        let requestID: JSONRPC.ID
        let query: String
        let frameworks: [String]
        let limit: Int
    }

    private struct SearchRow: Decodable {
        let assetID: String?
        let type: String?
        let framework: String?
        let title: String?
        let content: String?

        private enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case type
            case framework
            case title
            case content
        }
    }

    private let assetRoot: URL
    private let currentOSVersion: @Sendable () -> String
    private let processRunner: any ProcessRunning

    package init(
        assetRoot: URL = DocumentationSearchAssetLocator.defaultAssetRoot,
        currentOSVersion: @escaping @Sendable () -> String =
            DocumentationSearchAssetLocator.currentOperatingSystemVersionString,
        processRunner: any ProcessRunning = ProcessRunner()
    ) {
        self.assetRoot = assetRoot
        self.currentOSVersion = currentOSVersion
        self.processRunner = processRunner
    }

    package func descriptor(for target: DocumentationProviderTarget) async -> JSONValue? {
        guard installedAsset(for: target) != nil else {
            return nil
        }
        return Self.descriptor
    }

    package func callDocumentationSearch(
        requestData: Data,
        for target: DocumentationProviderTarget,
        timeout: TimeAmount?
    ) async throws -> Data {
        guard timeout?.nanoseconds != 0 else {
            throw TimeoutError()
        }
        let arguments = try Self.searchArguments(from: requestData)
        guard let asset = installedAsset(for: target) else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let rows = try await searchRows(arguments: arguments, asset: asset, timeout: timeout)
        return try Self.makeResponse(
            requestID: arguments.requestID,
            query: arguments.query,
            asset: asset,
            rows: rows
        )
    }

    private func installedAsset(
        for target: DocumentationProviderTarget
    ) -> DocumentationSearchInstalledAsset? {
        guard let scan = try? DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        else {
            return nil
        }
        return DocumentationSearchAssetLocator.bestAsset(
            for: target.xcodeVersion,
            currentOSVersion: currentOSVersion(),
            from: scan.assets
        )
    }

    private func searchRows(
        arguments: SearchArguments,
        asset: DocumentationSearchInstalledAsset,
        timeout: TimeAmount?
    ) async throws -> [SearchRow] {
        let sql = Self.searchSQL(arguments: arguments)
        let timeoutNanoseconds = timeout.flatMap { timeout in
            timeout.nanoseconds > 0 ? timeout.nanoseconds : nil
        }
        let request = ProcessRequest(
            label: "documentation-search-local",
            executablePath: "/usr/bin/sqlite3",
            arguments: [
                "-json",
                asset.indexURL.path,
                sql,
            ],
            input: nil,
            timeoutNanoseconds: timeoutNanoseconds
        )
        let output: ProcessOutput
        do {
            if let timeout, timeout.nanoseconds > 0 {
                output = try await ProcessOutputTimeoutWaiter().wait(
                    for: Task {
                        try await processRunner.run(request)
                    },
                    timeout: timeout
                )
            } else {
                output = try await processRunner.run(request)
            }
        } catch is ProcessTimeoutError {
            throw TimeoutError()
        }
        guard output.terminationStatus == 0 else {
            throw ControlPlane.Error.invalidResponse(
                "local DocumentationSearch sqlite failed: \(output.stderr)"
            )
        }
        guard let data = output.stdout.data(using: .utf8) else {
            return []
        }
        return try JSONDecoder().decode([SearchRow].self, from: data)
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

    private static func searchSQL(arguments: SearchArguments) -> String {
        let loweredQuery = arguments.query.lowercased()
        let terms = loweredQuery
            .split { character in
                character.isWhitespace || character.isNewline
            }
            .prefix(6)
            .map(String.init)
        let termClauses = terms.isEmpty
            ? [likeClause(for: loweredQuery)]
            : terms.map(likeClause(for:))
        var filters = termClauses
        if arguments.frameworks.isEmpty == false {
            let frameworks = arguments.frameworks
                .map { sqliteStringLiteral($0) }
                .joined(separator: ",")
            filters.append("framework IN (\(frameworks))")
        }
        let whereClause = filters.joined(separator: " AND ")
        let queryLiteral = sqliteStringLiteral(loweredQuery)
        let prefixLiteral = sqliteStringLiteral("\(loweredQuery)%")
        let containsLiteral = sqliteStringLiteral("%\(loweredQuery)%")
        return """
            SELECT asset_id,
                   type,
                   framework,
                   title,
                   substr(content, 1, 4000) AS content
            FROM attributes
            WHERE title IS NOT NULL
              AND content IS NOT NULL
              AND \(whereClause)
            ORDER BY CASE
                WHEN lower(title) = \(queryLiteral) THEN 0
                WHEN lower(title) LIKE \(prefixLiteral) THEN 1
                WHEN lower(title) LIKE \(containsLiteral) THEN 2
                WHEN lower(content) LIKE \(prefixLiteral) THEN 3
                ELSE 4
              END,
              CASE type WHEN 'symbol' THEN 0 WHEN 'article' THEN 1 ELSE 2 END,
              length(content)
            LIMIT \(arguments.limit)
            """
    }

    private static func likeClause(for term: String) -> String {
        let pattern = sqliteStringLiteral("%\(term)%")
        return "(lower(title) LIKE \(pattern) OR lower(content) LIKE \(pattern))"
    }

    private static func sqliteStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func makeResponse(
        requestID: JSONRPC.ID,
        query: String,
        asset: DocumentationSearchInstalledAsset,
        rows: [SearchRow]
    ) throws -> Data {
        let documents = rows.map { row -> [String: Any] in
            var document: [String: Any] = [
                "title": row.title ?? "",
                "type": row.type ?? "",
                "content": row.content ?? "",
            ]
            if let assetID = row.assetID {
                document["identifier"] = assetID
                document["url"] = "https://developer.apple.com\(assetID)"
            }
            if let framework = row.framework, framework.isEmpty == false {
                document["framework"] = framework
            }
            return document
        }
        var assetPayload: [String: Any] = [
            "path": asset.assetURL.path,
            "xcodeVersion": asset.xcodeVersion,
            "osVersion": asset.osVersion,
        ]
        if let documentationRelease = asset.documentationRelease {
            assetPayload["documentationRelease"] = documentationRelease
        }
        let payload: [String: Any] = [
            "query": query,
            "source": "installed-documentation-asset",
            "asset": assetPayload,
            "documents": documents,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadText = String(decoding: payloadData, as: UTF8.self)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID.value.foundationObject,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": payloadText,
                    ],
                ],
                "isError": false,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: response, options: [])
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

package actor DocumentationProviderConnection {
    private let session: any UpstreamSession
    private let clock: ClockClient
    private var eventTask: Task<Void, Never>?
    private var pendingResponses: [String: DocumentationPendingResponse] = [:]
    private var nextID: Int64 = 1

    package init(session: any UpstreamSession, clock: ClockClient = .liveValue) {
        self.session = session
        self.clock = clock
    }

    package func start() {
        guard eventTask == nil else { return }
        let session = session
        eventTask = Task { [weak self, session] in
            for await event in session.events {
                await self?.handle(event)
            }
            await self?.failAll(UpstreamSlotScheduler.AcquisitionError.unavailable)
        }
    }

    package func stop() async {
        eventTask?.cancel()
        eventTask = nil
        failAll(CancellationError())
        await session.stop()
    }

    package func sendNotification(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ControlPlane.Error.invalidResponse("invalid notification")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let result = await session.send(data)
        guard result == .accepted else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    package func call(_ requestData: Data, timeout: TimeAmount?) async throws -> Data {
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
        object["id"] = upstreamID
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ControlPlane.Error.invalidResponse("invalid DocumentationSearch request")
        }
        let upstreamData = try JSONSerialization.data(withJSONObject: object, options: [])

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = DocumentationPendingResponse(
                    originalID: originalID,
                    continuation: continuation
                )
                pendingResponses[upstreamIDKey] = pending
                scheduleTimeoutIfNeeded(id: upstreamIDKey, timeout: timeout, pending: pending)

                Task { [weak self, session] in
                    let sendResult = await session.send(upstreamData)
                    guard sendResult == .accepted else {
                        await self?.failPending(
                            id: upstreamIDKey,
                            error: UpstreamSlotScheduler.AcquisitionError.unavailable)
                        return
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
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
            var object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let responseID = JSONRPC.Message.Inspector.responseID(from: object),
            let pending = pendingResponses.removeValue(forKey: responseID.key)
        else {
            return
        }

        pending.timeoutTask?.cancel()
        object["id"] = pending.originalID.value.foundationObject
        guard JSONSerialization.isValidJSONObject(object),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
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

package actor SessionBackedDocumentationProviderTransport: DocumentationProviderRouting {
    private let sessionFactory: any DocumentationProviderSessionMaking
    private let clock: ClockClient
    private var connections: [String: DocumentationProviderConnection] = [:]

    package init(
        sessionFactory: any DocumentationProviderSessionMaking,
        clock: ClockClient = .liveValue
    ) {
        self.sessionFactory = sessionFactory
        self.clock = clock
    }

    package func openRoute(
        for target: DocumentationProviderTarget,
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
            try await connection.sendNotification([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ])
            connections[routeID] = connection
            return DocumentationProviderRoute(
                id: routeID,
                target: target,
                upstreamIndex: nil,
                serverVersion: serverVersion
            )
        } catch {
            await connection.stop()
            throw error
        }
    }

    package func toolsList(
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

    package func callDocumentationSearch(
        route: DocumentationProviderRoute,
        requestData: Data,
        timeout: TimeAmount?
    ) async throws -> Data {
        guard let connection = connections[route.id] else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        return try await connection.call(requestData, timeout: timeout)
    }

    package func close(route: DocumentationProviderRoute) async {
        guard let connection = connections.removeValue(forKey: route.id) else {
            return
        }
        await connection.stop()
    }

    package func shutdown() async {
        let connections = self.connections
        self.connections.removeAll()
        for connection in connections.values {
            await connection.stop()
        }
    }

    private static func makeInitializeRequestData(
        initializeParams: [String: JSONValue]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "initialize",
                "method": "initialize",
                "params": initializeParams.mapValues(\.foundationObject),
            ],
            options: []
        )
    }

    private static func makeToolsListRequestData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "tools-list",
                "method": "tools/list",
            ],
            options: []
        )
    }
}

package actor DocumentationProviderManager: DocumentationProviderManaging {
    private enum DescriptorSource: Sendable, Equatable {
        case xcode
        case installedDocumentationAsset
    }

    private struct CandidateProfile: Sendable {
        let id: UUID
        let target: DocumentationProviderTarget
        let route: DocumentationProviderRoute
        var descriptor: JSONValue?
        var descriptorSource: DescriptorSource?
        let serverVersion: String
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
    private let pinnedProcessID: pid_t?
    private let initializeParams: [String: JSONValue]
    private let serviceRepairer: any DocumentationSearchServiceRepairing
    private let localSearchProvider: any DocumentationSearchProviding
    private let clock: ClockClient
    private let logger: Logger
    private let descriptorRefreshRetryDelayNanoseconds: Int64 = 250_000_000
    private var activeProvider: ActiveProvider?
    private var preparedProviders: [pid_t: CandidateProfile] = [:]
    private var providerPreparations: [pid_t: ProviderPreparation] = [:]
    private var unusableProcessIDs: Set<pid_t> = []
    private var serviceRepairAttemptedProcessIDs: Set<pid_t> = []
    private var isShutdown = false

    package init(
        discovery: any XcodeTargetDiscovering,
        transport: any DocumentationProviderRouting,
        providerSelectionTimeout: TimeAmount? = .seconds(30),
        pinnedProcessID: pid_t? = nil,
        initializeParams: [String: JSONValue] = InitializeHandshakeJSON.defaultParams(),
        serviceRepairer: any DocumentationSearchServiceRepairing = NoopDocumentationSearchServiceRepairer(),
        localSearchProvider: any DocumentationSearchProviding = UnavailableDocumentationSearchProvider(),
        clock: ClockClient = .liveValue,
        logger: Logger = ProxyLogging.make("documentation.provider")
    ) {
        self.discovery = discovery
        self.transport = transport
        self.providerSelectionTimeout = providerSelectionTimeout
        self.pinnedProcessID = pinnedProcessID
        self.initializeParams = initializeParams
        self.serviceRepairer = serviceRepairer
        self.localSearchProvider = localSearchProvider
        self.clock = clock
        self.logger = logger
    }

    package init(
        discovery: any XcodeTargetDiscovering,
        sessionFactory: any DocumentationProviderSessionMaking,
        providerSelectionTimeout: TimeAmount? = .seconds(30),
        pinnedProcessID: pid_t? = nil,
        initializeParams: [String: JSONValue] = InitializeHandshakeJSON.defaultParams(),
        serviceRepairer: any DocumentationSearchServiceRepairing = NoopDocumentationSearchServiceRepairer(),
        localSearchProvider: any DocumentationSearchProviding = UnavailableDocumentationSearchProvider(),
        clock: ClockClient = .liveValue,
        logger: Logger = ProxyLogging.make("documentation.provider")
    ) {
        self.init(
            discovery: discovery,
            transport: SessionBackedDocumentationProviderTransport(
                sessionFactory: sessionFactory,
                clock: clock
            ),
            providerSelectionTimeout: providerSelectionTimeout,
            pinnedProcessID: pinnedProcessID,
            initializeParams: initializeParams,
            serviceRepairer: serviceRepairer,
            localSearchProvider: localSearchProvider,
            clock: clock,
            logger: logger
        )
    }

    package func startBackgroundDiscovery(requestTimeout: TimeAmount?) async
        -> DocumentationProvider.ToolListUpdate
    {
        guard !isShutdown else { return .unavailable }
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        let deadline = Deadline.fromNow(requestTimeout, clock: clock)
        let targets = orderedTargets(excluding: [])
        guard targets.isEmpty == false else {
            return .unavailable
        }
        for target in targets {
            guard !Task.isCancelled, !isShutdown else {
                return .unavailable
            }
            guard unusableProcessIDs.contains(target.processID) == false else {
                continue
            }
            do {
                let profile = try await preparedProvider(
                    for: target,
                    requestTimeout: remainingTimeout(until: deadline),
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
        return toolListUpdateFromCachedState(requestTimeout: requestTimeout)
    }

    package func toolListUpdate(requestTimeout: TimeAmount?) async
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
        return toolListUpdateFromCachedState(requestTimeout: requestTimeout)
    }

    private func toolListUpdateFromCachedState(requestTimeout: TimeAmount?)
        -> DocumentationProvider.ToolListUpdate
    {
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        if let activeProvider {
            guard let descriptor = activeProvider.profile.descriptor else {
                return .unchanged
            }
            return .available(descriptor)
        }
        let targets = orderedTargets(excluding: [])
        guard targets.isEmpty == false else {
            return .unavailable
        }
        for target in targets {
            if let descriptor = preparedProviders[target.processID]?.descriptor {
                return .available(descriptor)
            }
        }
        let targetIDs = Set(targets.map(\.processID))
        if targetIDs.isSubset(of: unusableProcessIDs) {
            return .unavailable
        }
        return .unchanged
    }

    package func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome {
        guard !isShutdown else {
            return .unavailable(.noAvailableProvider)
        }
        let deadline = Deadline.fromNow(requestTimeoutOverride, clock: clock)
        var rejectedProcessIDs: Set<pid_t> = []
        var invalidatedProvider = false

        while !Task.isCancelled {
            if let deadline, deadline.hasExpired {
                return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
            }
            if let activeProvider,
                rejectedProcessIDs.contains(activeProvider.profile.target.processID) == false,
                activeProviderIsCurrentBest(
                    activeProvider,
                    excluding: rejectedProcessIDs.union(unusableProcessIDs)
                )
            {
                let fallbackTargets = orderedTargets(
                    excluding: rejectedProcessIDs
                        .union(unusableProcessIDs)
                        .union([activeProvider.profile.target.processID])
                )
                let activeDeadline = makeDeadline(
                    fromTimeout: timeoutForCandidate(
                        until: deadline,
                        remainingCandidateCount: fallbackTargets.count + 1
                    )
                )
                switch try await attemptDocumentationSearch(
                    requestData: requestData,
                    provider: activeProvider,
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
                    rejectedProcessIDs.insert(processID)
                    invalidatedProvider = true
                    if permanentlyUnusable {
                        unusableProcessIDs.insert(processID)
                    }
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
                excluding: rejectedProcessIDs.union(unusableProcessIDs)
            )
            guard targets.isEmpty == false else {
                try Task.checkCancellation()
                if let deadline, deadline.hasExpired {
                    return .failed(TimeoutError(), invalidatedProvider: invalidatedProvider)
                }
                return .unavailable(.noAvailableProvider)
            }

            var progressed = false
            for (index, target) in targets.enumerated() {
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
                        fetchDescriptor: false
                    )
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
                        rejectedProcessIDs.insert(processID)
                        invalidatedProvider = true
                        progressed = true
                        if permanentlyUnusable {
                            unusableProcessIDs.insert(processID)
                        }
                        continue
                    case .failed(let error):
                        rejectedProcessIDs.insert(target.processID)
                        invalidatedProvider = true
                        progressed = true
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
        await transport.close(route: previous.profile.route)
        return true
    }

    private enum DocumentationAttemptResult: Sendable {
        case success(data: Data, replacementProfile: CandidateProfile?)
        case rejected(processID: pid_t, permanentlyUnusable: Bool)
        case failed(any Error)
    }

    private func attemptDocumentationSearch(
        requestData: Data,
        provider: ActiveProvider,
        deadline: Deadline?
    ) async throws -> DocumentationAttemptResult {
        let processID = provider.profile.target.processID
        if provider.profile.descriptorSource == .installedDocumentationAsset {
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
                return .failed(error)
            }
        }
        do {
            let response = try await transport.callDocumentationSearch(
                route: provider.profile.route,
                requestData: requestData,
                timeout: remainingTimeout(until: deadline)
            )
            guard !DocumentationProvider.ToolCatalog.responseIsDocumentationNotEnabled(response)
            else {
                if let fallback = try await callInstalledDocumentationAssetFallbackIfAvailable(
                    requestData: requestData,
                    target: provider.profile.target,
                    deadline: deadline
                ) {
                    return .success(
                        data: fallback.responseData,
                        replacementProfile: profileByUsingInstalledDocumentationAssetFallback(
                            provider.profile,
                            fallback: fallback
                        )
                    )
                }
                await invalidate(provider, reason: "documentation_search_tool_error")
                return .rejected(processID: processID, permanentlyUnusable: true)
            }
            if DocumentationProvider.ToolCatalog.responseIsDocumentationProviderFailure(response) {
                if let fallback = try await callInstalledDocumentationAssetFallbackIfAvailable(
                    requestData: requestData,
                    target: provider.profile.target,
                    deadline: deadline
                ) {
                    return .success(
                        data: fallback.responseData,
                        replacementProfile: profileByUsingInstalledDocumentationAssetFallback(
                            provider.profile,
                            fallback: fallback
                        )
                    )
                }
                await invalidate(provider, reason: "documentation_search_provider_failure")
                return .rejected(processID: processID, permanentlyUnusable: false)
            }
            return .success(data: response, replacementProfile: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let fallback = try await callInstalledDocumentationAssetFallbackIfAvailable(
                requestData: requestData,
                target: provider.profile.target,
                deadline: deadline
            ) {
                return .success(
                    data: fallback.responseData,
                    replacementProfile: profileByUsingInstalledDocumentationAssetFallback(
                        provider.profile,
                        fallback: fallback
                    )
                )
            }
            await invalidate(provider, reason: "documentation_provider_call_failed")
            return .failed(error)
        }
    }

    private func callInstalledDocumentationAssetFallbackIfAvailable(
        requestData: Data,
        target: DocumentationProviderTarget,
        deadline: Deadline?
    ) async throws -> InstalledDocumentationAssetFallback? {
        do {
            return try await callInstalledDocumentationAssetFallback(
                requestData: requestData,
                target: target,
                deadline: deadline
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug(
                "Installed documentation asset fallback failed",
                metadata: candidateLogMetadata(target: target, error: error)
            )
            return nil
        }
    }

    package func invalidate(reason _: String) async {
        let preparations = providerPreparations
        providerPreparations.removeAll()
        for preparation in preparations.values {
            preparation.task.cancel()
        }
        let prepared = preparedProviders
        preparedProviders.removeAll()
        let provider = activeProvider
        activeProvider = nil
        for profile in prepared.values where profile.id != provider?.profile.id {
            await transport.close(route: profile.route)
        }
        if let provider {
            await transport.close(route: provider.profile.route)
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
        await transport.close(route: replacedProfile.route)
    }

    package func shutdown() async {
        isShutdown = true
        await invalidate(reason: "shutdown")
        await transport.shutdown()
    }

    private func preparedProvider(
        for target: DocumentationProviderTarget,
        requestTimeout: TimeAmount?,
        fetchDescriptor: Bool
    ) async throws -> CandidateProfile {
        if let activeProvider, activeProvider.profile.target.processID == target.processID {
            if fetchDescriptor, activeProvider.profile.descriptor == nil {
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
            if fetchDescriptor, prepared.descriptor == nil {
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
        } else {
            let timeout = providerSelectionTimeout
            preparation = ProviderPreparation(
                task: Task {
                    try await self.openProviderRoute(
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
            throw TimeoutError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            providerPreparations.removeValue(forKey: target.processID)
            throw error
        }
        providerPreparations.removeValue(forKey: target.processID)
        if isShutdown {
            await transport.close(route: profile.route)
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
            if fetchDescriptor, activeProvider.profile.descriptor == nil {
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
            if fetchDescriptor, prepared.descriptor == nil {
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
        if fetchDescriptor, prepared.descriptor == nil {
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
            return primary
        }
        var merged = primary
        merged.descriptor = fallback.descriptor
        merged.descriptorSource = fallback.descriptorSource
        return merged
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
        await transport.close(route: provider.profile.route)
    }

    private func orderedTargets(
        excluding excludedProcessIDs: Set<pid_t>
    ) -> [DocumentationProviderTarget] {
        let discoveredTargets = discovery.runningXcodeTargets()
        let filtered: [DocumentationProviderTarget]
        if let pinnedProcessID {
            filtered = discoveredTargets.filter {
                $0.processID == pinnedProcessID
                    && excludedProcessIDs.contains($0.processID) == false
            }
        } else {
            filtered = discoveredTargets.filter {
                excludedProcessIDs.contains($0.processID) == false
            }
        }
        return filtered.sorted { lhs, rhs in
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
        target: DocumentationProviderTarget,
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
        let route = try await transport.openRoute(
            for: target,
            requestTimeout: startupTimeout,
            initializeParams: initializeParams
        )
        do {
            try Task.checkCancellation()
            guard !isShutdown else {
                throw CancellationError()
            }
            guard remainingTimeout(until: startupDeadline)?.nanoseconds != 0 else {
                throw TimeoutError()
            }
        } catch {
            await transport.close(route: route)
            throw error
        }
        return CandidateProfile(
            id: UUID(),
            target: target,
            route: route,
            descriptor: nil,
            descriptorSource: nil,
            serverVersion: route.serverVersion
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
        let toolsResult = try await transport.toolsList(
            route: profile.route,
            timeout: toolsListTimeout
        )
        updated.descriptor = DocumentationProvider.ToolCatalog.descriptor(in: toolsResult)
        updated.descriptorSource = updated.descriptor == nil ? nil : .xcode
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
            if replacement.route.id != profile.route.id {
                await transport.close(route: profile.route)
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
            return profile
        }
    }

    private func repairDocumentationSearch(
        for target: DocumentationProviderTarget,
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
            timeout: timeout
        )
        return result.repairResult
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
        updated.descriptor = descriptor
        updated.descriptorSource = .installedDocumentationAsset
        return updated
    }

    private func profileByUsingInstalledDocumentationAssetFallback(
        _ profile: CandidateProfile,
        fallback: InstalledDocumentationAssetFallback
    ) -> CandidateProfile {
        var updated = profile
        updated.descriptor = fallback.descriptor
        updated.descriptorSource = .installedDocumentationAsset
        return updated
    }

    private func callInstalledDocumentationAssetFallback(
        requestData: Data,
        target: DocumentationProviderTarget,
        deadline: Deadline?
    ) async throws -> InstalledDocumentationAssetFallback? {
        guard let descriptor = await localSearchProvider.descriptor(for: target) else {
            return nil
        }
        logger.warning(
            "Falling back to installed documentation asset for DocumentationSearch",
            metadata: [
                "pid": .string("\(target.processID)"),
                "app_path": .string(target.appPath),
                "xcode_version": .string(target.xcodeVersion),
            ]
        )
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

    package static func resultValue(from responseData: Data) throws -> JSONValue {
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

    package static func serverVersion(fromInitializeResponse data: Data) -> String? {
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
            return nil
        }
        guard remaining.nanoseconds > 0 else {
            return .nanoseconds(0)
        }
        guard remainingCandidateCount > 1 else {
            return remaining
        }
        return .nanoseconds(max(1, remaining.nanoseconds / Int64(remainingCandidateCount)))
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
        target: DocumentationProviderTarget,
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
