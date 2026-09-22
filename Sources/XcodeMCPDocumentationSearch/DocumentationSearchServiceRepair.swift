import Foundation
import NIOCore
import XcodeMCPCore

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

package struct InstalledDocumentationSearchRepairer: Sendable {
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
        readConfigURLOverride: (@Sendable () -> String?)? = nil,
        writeConfigURLOverride: (@Sendable (String) -> Bool)? = nil
    ) {
        self.assetRoot = assetRoot
        self.currentOSVersion = currentOSVersion
        self.readConfigURLOverride = readConfigURLOverride ?? Self.currentConfigURLOverride
        self.writeConfigURLOverride = writeConfigURLOverride ?? Self.writeConfigURLOverride
    }

    package func repair(
        for target: DocumentationSearchInstallation
    ) async -> DocumentationSearchServiceRepairResult {
        let scan: DocumentationSearchAssetScan
        do {
            scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        } catch {
            return .failed("asset_scan_failed: \(error)")
        }
        let hostOSVersion = currentOSVersion()
        guard let asset = DocumentationSearchAssetLocator.bestHostCompatibleAsset(
            for: target.xcodeVersion,
            currentOSVersion: hostOSVersion,
            from: scan.assets
        ) else {
            guard scan.assets.isEmpty == false else {
                return .skipped(scan.noAssetReason)
            }
            return .skipped(
                "no_host_compatible_documentation_asset current_os=\(hostOSVersion)"
            )
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
