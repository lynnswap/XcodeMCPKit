import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class ProcessToolCatalogRegistry: Sendable {
    struct Catalog: Sendable {
        let target: XcodeProcessTarget
        let upstreamIndex: Int
        let rawResult: JSONValue
        let toolsByName: [String: JSONValue]
        let fingerprintsByName: [String: String]
        let ownerBoundToolNames: Set<String>

        var toolNames: Set<String> {
            Set(toolsByName.keys)
        }
    }

    struct AvailableToolCatalog: Sendable {
        let rawResult: JSONValue
        let sourceUpstream: Int?
        let processIDs: Set<pid_t>

        var isEmpty: Bool {
            processIDs.isEmpty
        }
    }

    struct DebugSnapshot: Codable, Sendable {
        let processID: Int32
        let appPath: String
        let xcodeVersion: String
        let upstreamIndex: Int
        let toolCount: Int
        let ownerBoundToolCount: Int
        let tabOwnerCount: Int
        let workspaceOwnerCount: Int
        let isCanonicalSource: Bool
        let exposurePolicy: String
        let missingFromExposedCatalog: [String]
        let extraBeyondExposedCatalog: [String]
        let schemaConflicts: [String]
    }

    private struct State: Sendable {
        var catalogsByProcessID: [pid_t: Catalog] = [:]
        var processIDByUpstreamIndex: [Int: pid_t] = [:]
    }

    private let state = NIOLockedValueBox(State())

    init() {}

    func record(
        target: XcodeProcessTarget,
        upstreamIndex: Int,
        associatedUpstreamIndices: [Int] = [],
        rawResult: JSONValue
    ) {
        let catalog = Catalog(
            target: target,
            upstreamIndex: upstreamIndex,
            rawResult: rawResult,
            toolsByName: Self.toolsByName(in: rawResult),
            fingerprintsByName: Self.toolFingerprintsByName(in: rawResult),
            ownerBoundToolNames: Self.ownerBoundToolNames(in: rawResult)
        )
        state.withLockedValue { state in
            state.catalogsByProcessID[target.processID] = catalog
            state.processIDByUpstreamIndex[upstreamIndex] = target.processID
            for associatedUpstreamIndex in associatedUpstreamIndices {
                state.processIDByUpstreamIndex[associatedUpstreamIndex] = target.processID
            }
        }
    }

    func reset() {
        state.withLockedValue { state in
            state.catalogsByProcessID.removeAll()
            state.processIDByUpstreamIndex.removeAll()
        }
    }

    func removeCatalog(forUpstreamIndex upstreamIndex: Int) {
        state.withLockedValue { state in
            guard let processID = state.processIDByUpstreamIndex[upstreamIndex]
            else { return }
            state.catalogsByProcessID.removeValue(forKey: processID)
            state.processIDByUpstreamIndex = state.processIDByUpstreamIndex.filter {
                $0.value != processID
            }
        }
    }

    func removeUpstreamMapping(
        forUpstreamIndex upstreamIndex: Int,
        replacementUpstreamIndex: Int? = nil
    ) {
        state.withLockedValue { state in
            guard let processID = state.processIDByUpstreamIndex.removeValue(forKey: upstreamIndex)
            else { return }
            if let replacementUpstreamIndex {
                state.processIDByUpstreamIndex[replacementUpstreamIndex] = processID
            }
            guard let replacementUpstreamIndex,
                  let catalog = state.catalogsByProcessID[processID],
                  catalog.upstreamIndex == upstreamIndex else {
                return
            }
            state.catalogsByProcessID[processID] = Catalog(
                target: catalog.target,
                upstreamIndex: replacementUpstreamIndex,
                rawResult: catalog.rawResult,
                toolsByName: catalog.toolsByName,
                fingerprintsByName: catalog.fingerprintsByName,
                ownerBoundToolNames: catalog.ownerBoundToolNames
            )
        }
    }

    func removeCatalog(forProcessID processID: pid_t) {
        state.withLockedValue { state in
            state.catalogsByProcessID.removeValue(forKey: processID)
            state.processIDByUpstreamIndex = state.processIDByUpstreamIndex.filter {
                $0.value != processID
            }
        }
    }

    func catalog(forUpstreamIndex upstreamIndex: Int) -> Catalog? {
        state.withLockedValue { state in
            guard let processID = state.processIDByUpstreamIndex[upstreamIndex] else {
                return nil
            }
            return state.catalogsByProcessID[processID]
        }
    }

    func catalog(forProcessID processID: pid_t) -> Catalog? {
        state.withLockedValue { state in
            state.catalogsByProcessID[processID]
        }
    }

    func unionToolsListResult() -> JSONValue? {
        state.withLockedValue { state in
            Self.unionToolsListResult(from: Array(state.catalogsByProcessID.values))
        }
    }

    func availableToolCatalogSurface(processIDs: Set<pid_t>? = nil) -> AvailableToolCatalog? {
        state.withLockedValue { state in
            let catalogs = state.catalogsByProcessID.values.filter { catalog in
                processIDs?.contains(catalog.target.processID) ?? true
            }
            guard let rawResult = Self.unionToolsListResult(from: catalogs) else {
                return nil
            }
            return AvailableToolCatalog(
                rawResult: rawResult,
                sourceUpstream: catalogs.sorted(by: Self.catalogSort).first?.upstreamIndex,
                processIDs: Set(catalogs.map { $0.target.processID })
            )
        }
    }

    func representativeSourceUpstream() -> Int? {
        state.withLockedValue { state in
            state.catalogsByProcessID.values.sorted(by: Self.catalogSort).first?.upstreamIndex
        }
    }

    func isOwnerBoundTool(_ toolName: String) -> Bool {
        state.withLockedValue { state in
            state.catalogsByProcessID.values.contains {
                $0.ownerBoundToolNames.contains(toolName)
            }
        }
    }

    func processIDsHavingTool(_ toolName: String) -> Set<pid_t> {
        state.withLockedValue { state in
            Set(
                state.catalogsByProcessID.compactMap { processID, catalog in
                    catalog.toolsByName[toolName] == nil ? nil : processID
                }
            )
        }
    }

    func processIDsWithCatalog() -> Set<pid_t> {
        state.withLockedValue { state in
            Set(state.catalogsByProcessID.keys)
        }
    }

    func hasTool(_ toolName: String, upstreamIndex: Int) -> Bool {
        catalog(forUpstreamIndex: upstreamIndex)?.toolsByName[toolName] != nil
    }

    func hasTool(_ toolName: String, processID: pid_t) -> Bool {
        catalog(forProcessID: processID)?.toolsByName[toolName] != nil
    }

    func toolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue? {
        catalog(forUpstreamIndex: upstreamIndex)?.rawResult
    }

    func debugSnapshots(
        exposedCatalog: JSONValue?,
        canonicalSourceUpstream: Int?,
        tabOwnerCountsByProcessID: [pid_t: Int],
        workspaceOwnerCountsByProcessID: [pid_t: Int]
    ) -> [DebugSnapshot] {
        let exposedNames = Set(Self.toolsByName(in: exposedCatalog).keys)
        let conflicts = Self.schemaConflicts(in: state.withLockedValue {
            Array($0.catalogsByProcessID.values)
        })
        return state.withLockedValue { state in
            state.catalogsByProcessID.values.sorted(by: Self.catalogSort).map { catalog in
                let toolNames = catalog.toolNames
                return DebugSnapshot(
                    processID: Int32(catalog.target.processID),
                    appPath: catalog.target.appPath,
                    xcodeVersion: catalog.target.xcodeVersion,
                    upstreamIndex: catalog.upstreamIndex,
                    toolCount: toolNames.count,
                    ownerBoundToolCount: catalog.ownerBoundToolNames.count,
                    tabOwnerCount: tabOwnerCountsByProcessID[catalog.target.processID, default: 0],
                    workspaceOwnerCount: workspaceOwnerCountsByProcessID[
                        catalog.target.processID,
                        default: 0
                    ],
                    isCanonicalSource: catalog.upstreamIndex == canonicalSourceUpstream,
                    exposurePolicy: "available_route_catalog_surface",
                    missingFromExposedCatalog: Array(toolNames.subtracting(exposedNames)).sorted(),
                    extraBeyondExposedCatalog: Array(exposedNames.subtracting(toolNames)).sorted(),
                    schemaConflicts: conflicts
                )
            }
        }
    }

    static func toolsByName(in result: JSONValue?) -> [String: JSONValue] {
        guard let result,
              case .object(let object) = result,
              case .array(let tools)? = object["tools"] else {
            return [:]
        }
        var toolsByName: [String: JSONValue] = [:]
        for tool in tools {
            guard case .object(let toolObject) = tool,
                  case .string(let name)? = toolObject["name"] else {
                continue
            }
            toolsByName[name] = tool
        }
        return toolsByName
    }

    static func isOwnerBoundTool(_ tool: JSONValue) -> Bool {
        guard case .object(let toolObject) = tool,
              case .object(let inputSchema)? = toolObject["inputSchema"] else {
            return false
        }
        if case .object(let properties)? = inputSchema["properties"],
           properties["tabIdentifier"] != nil || properties["workspacePath"] != nil {
            return true
        }
        if case .array(let required)? = inputSchema["required"] {
            for value in required {
                guard case .string(let key) = value else { continue }
                if key == "tabIdentifier" || key == "workspacePath" {
                    return true
                }
            }
        }
        return false
    }

    private static func ownerBoundToolNames(in result: JSONValue) -> Set<String> {
        Set(
            toolsByName(in: result).compactMap { name, tool in
                isOwnerBoundTool(tool) ? name : nil
            }
        )
    }

    private static func toolFingerprintsByName(in result: JSONValue) -> [String: String] {
        toolsByName(in: result).mapValues(fingerprint)
    }

    private static func unionToolsListResult(from catalogs: [Catalog]) -> JSONValue? {
        guard catalogs.isEmpty == false else {
            return nil
        }
        let sortedCatalogs = catalogs.sorted(by: catalogSort)
        var selectedTools: [String: JSONValue] = [:]
        for catalog in sortedCatalogs {
            for (name, tool) in catalog.toolsByName where selectedTools[name] == nil {
                selectedTools[name] = tool
            }
        }
        let tools = selectedTools.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.compactMap { selectedTools[$0] }
        return .object(["tools": .array(tools)])
    }

    private static func schemaConflicts(in catalogs: [Catalog]) -> [String] {
        var fingerprintsByTool: [String: Set<String>] = [:]
        for catalog in catalogs {
            for (name, fingerprint) in catalog.fingerprintsByName {
                fingerprintsByTool[name, default: []].insert(fingerprint)
            }
        }
        return fingerprintsByTool.compactMap { name, fingerprints in
            fingerprints.count > 1 ? name : nil
        }.sorted()
    }

    private static func catalogSort(_ lhs: Catalog, _ rhs: Catalog) -> Bool {
        let versionComparison = lhs.target.xcodeVersion.compare(
            rhs.target.xcodeVersion,
            options: [.numeric]
        )
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }
        if lhs.target.appPath != rhs.target.appPath {
            return lhs.target.appPath < rhs.target.appPath
        }
        return lhs.target.processID < rhs.target.processID
    }

    private static func fingerprint(_ value: JSONValue) -> String {
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(
                  withJSONObject: value.foundationObject,
                  options: [.sortedKeys]
              ) else {
            return String(describing: value.foundationObject)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
