import Foundation
import NIOCore
import XcodeMCPCore

private actor DocumentationAssetSelectionCache {
    private struct SelectionKey: Hashable {
        let appPath: String
        let xcodeVersion: String
        let currentOSVersion: String
    }

    private struct RootSignature: Equatable {
        let path: String
        let modificationDate: Date?
    }

    private var cachedRootSignature: RootSignature?
    private var cachedAssets: [DocumentationSearchInstalledAsset]?
    private var successfulAssetPathBySelectionKey: [SelectionKey: String] = [:]

    func installedAssets(
        assetRoot: URL,
        target: DocumentationSearchInstallation,
        currentOSVersion: String
    ) -> [DocumentationSearchInstalledAsset] {
        let signature = Self.rootSignature(for: assetRoot)
        let assets: [DocumentationSearchInstalledAsset]
        if cachedRootSignature == signature, let cachedAssets {
            assets = cachedAssets
        } else {
            guard let scan = try? DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
            else {
                return []
            }
            cachedRootSignature = signature
            cachedAssets = scan.assets
            successfulAssetPathBySelectionKey.removeAll()
            assets = scan.assets
        }
        var orderedAssets = DocumentationSearchAssetLocator
            .hostCompatibleAssetsOrderedByCompatibility(
                for: target.xcodeVersion,
                currentOSVersion: currentOSVersion,
                from: assets
            )
        let key = SelectionKey(
            appPath: target.appPath,
            xcodeVersion: target.xcodeVersion,
            currentOSVersion: currentOSVersion
        )
        guard let successfulAssetPath = successfulAssetPathBySelectionKey[key],
              let index = orderedAssets.firstIndex(where: {
                  $0.assetURL.path == successfulAssetPath
              }),
              index != orderedAssets.startIndex else {
            return orderedAssets
        }
        orderedAssets.insert(orderedAssets.remove(at: index), at: orderedAssets.startIndex)
        return orderedAssets
    }

    func recordSuccessfulAsset(
        _ asset: DocumentationSearchInstalledAsset,
        assetRoot: URL,
        target: DocumentationSearchInstallation,
        currentOSVersion: String
    ) {
        guard cachedRootSignature == Self.rootSignature(for: assetRoot),
              cachedAssets?.contains(asset) == true else {
            return
        }
        successfulAssetPathBySelectionKey[
            SelectionKey(
                appPath: target.appPath,
                xcodeVersion: target.xcodeVersion,
                currentOSVersion: currentOSVersion
            )
        ] = asset.assetURL.path
    }

    private static func rootSignature(for assetRoot: URL) -> RootSignature {
        let modificationDate = (try? FileManager.default.attributesOfItem(
            atPath: assetRoot.path
        )[.modificationDate]) as? Date
        return RootSignature(path: assetRoot.path, modificationDate: modificationDate)
    }
}

package struct InstalledDocumentationSearch: Sendable {
    private let assetRoot: URL
    private let assetCache = DocumentationAssetSelectionCache()
    private let invoker: any DocumentationSearchActionInvoking
    private let currentOSVersion: @Sendable () -> String

    package init(
        assetRoot: URL = DocumentationSearchAssetLocator.defaultAssetRoot,
        invoker: any DocumentationSearchActionInvoking = LiveDocumentationSearchActionInvoker(),
        currentOSVersion: @escaping @Sendable () -> String = DocumentationSearchAssetLocator.currentOperatingSystemVersionString
    ) {
        self.assetRoot = assetRoot
        self.invoker = invoker
        self.currentOSVersion = currentOSVersion
    }

    package func isAvailable(for installation: DocumentationSearchInstallation) async -> Bool {
        guard await installedAssets(for: installation).isEmpty == false else { return false }
        return await invoker.isAvailable(for: installation)
    }

    package func search(
        _ query: String, frameworks: [String], limit: Int?,
        in installation: DocumentationSearchInstallation, timeout: TimeAmount?
    ) async throws -> DocumentationSearchActionOutput {
        guard timeout.map({ $0.nanoseconds > 0 }) ?? true else { throw TimeoutError() }
        let currentOSVersion = currentOSVersion()
        let assets = await installedAssets(
            for: installation,
            currentOSVersion: currentOSVersion
        )
        guard assets.isEmpty == false else {
            throw DocumentationSearchBackendError.unavailable
        }
        let deadline = Deadline.fromNow(timeout)
        var lastTextEncoderInitializationError: (any Error)?
        for asset in assets {
            let remainingTimeout = deadline?.remaining()
            if remainingTimeout?.nanoseconds == 0 {
                throw TimeoutError()
            }
            do {
                let output = try await invoker.invoke(
                    DocumentationSearchActionInvocation(
                        installation: installation,
                        asset: asset,
                        query: query,
                        frameworks: frameworks,
                        limit: limit
                    ),
                    timeout: remainingTimeout
                )
                await assetCache.recordSuccessfulAsset(
                    asset,
                    assetRoot: assetRoot,
                    target: installation,
                    currentOSVersion: currentOSVersion
                )
                return output
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isTextEncoderInitializationFailure(error) else {
                    throw error
                }
                lastTextEncoderInitializationError = error
            }
        }
        throw lastTextEncoderInitializationError
            ?? DocumentationSearchBackendError.unavailable
    }

    private func installedAssets(
        for target: DocumentationSearchInstallation,
        currentOSVersion: String? = nil
    ) async -> [DocumentationSearchInstalledAsset] {
        await assetCache.installedAssets(
            assetRoot: assetRoot,
            target: target,
            currentOSVersion: currentOSVersion ?? self.currentOSVersion()
        )
    }

    private static func isTextEncoderInitializationFailure(_ error: any Error) -> Bool {
        guard let controlPlaneError = error as? DocumentationSearchBackendError,
              case .invalidResponse(let message) = controlPlaneError else {
            return false
        }
        return documentationSearchTextEncoderInitializationFailed(message)
    }

}
