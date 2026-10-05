import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

// NSArgumentDomain is process-wide, including for distinct UserDefaults suites.
@Suite(.serialized)
struct NativeDocumentationSearchAssetTests {
    @Test func selectsLatestXcodeDocumentationThenRelease() throws {
        let fixture = try AssetFixture()
        defer { fixture.remove() }
        _ = try fixture.asset("old", xcodeVersion: "26.5", release: 900339)
        _ = try fixture.asset("current", xcodeVersion: "27.0", release: 2023)
        let newest = try fixture.asset("newest", xcodeVersion: "27.0.0", release: "2024", osVersion: "99.0")

        let latest = try NativeDocumentationSearchAsset.latest(in: fixture.root)
        let selected = try #require(latest)
        #expect(try sameFile(selected.configURL, newest))
        #expect(selected.documentationRelease == 2024)
    }

    @Test(arguments: ["config.json", "documentation-db/index.sql", "Info.plist"])
    func incompleteNewAssetDoesNotHideInstalledIndex(missingFile: String) throws {
        let fixture = try AssetFixture()
        defer { fixture.remove() }
        let installed = try fixture.asset("installed", xcodeVersion: "27.0", release: 2023)
        let incomplete = try fixture.asset("incomplete", xcodeVersion: "27.1", release: 3000)
        let base = missingFile == "Info.plist"
            ? incomplete.deletingLastPathComponent().deletingLastPathComponent()
            : incomplete.deletingLastPathComponent()
        try FileManager.default.removeItem(at: base.appendingPathComponent(missingFile))

        let selected = try NativeDocumentationSearchAsset.latest(in: fixture.root)
        #expect(try sameFile(#require(selected).configURL, installed))
    }

    @Test func configuresDirectSearchWithoutPersistingUserSettings() throws {
        let fixture = try AssetFixture()
        defer { fixture.remove() }
        let configURL = try fixture.asset("installed", xcodeVersion: "27.0", release: 2023)
        let domainName = "NativeDocumentationSearchAssetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domainName))
        defer { defaults.removePersistentDomain(forName: domainName) }
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let key = NativeDocumentationSearchAsset.configURLKey
        defaults.setPersistentDomain([key: "/old/config.json"], forName: domainName)
        defaults.setVolatileDomain(["unrelated": "preserved"], forName: UserDefaults.argumentDomain)

        _ = try NativeDocumentationSearchAsset.configureLatest(in: fixture.root, defaults: defaults)

        let selectedPath = try #require(defaults.string(forKey: key))
        #expect(try sameFile(URL(fileURLWithPath: selectedPath), configURL))
        #expect(defaults.string(forKey: "unrelated") == "preserved")
        #expect(defaults.persistentDomain(forName: domainName)?[key] as? String == "/old/config.json")
        let newConfig = try fixture.asset("updated", xcodeVersion: "27.1", release: 3000)
        _ = try NativeDocumentationSearchAsset.configureLatest(in: fixture.root, defaults: defaults)
        let updatedPath = try #require(defaults.string(forKey: key))
        #expect(try sameFile(URL(fileURLWithPath: updatedPath), newConfig))
    }

    @Test func missingAssetsPreserveExistingConfiguration() throws {
        let fixture = try AssetFixture()
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: "NativeDocumentationSearchAssetTests.\(UUID())"))
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let key = NativeDocumentationSearchAsset.configURLKey
        defaults.setVolatileDomain([key: "/custom/config.json"], forName: UserDefaults.argumentDomain)

        #expect(try NativeDocumentationSearchAsset.configureLatest(in: fixture.root, defaults: defaults) == nil)
        #expect(defaults.string(forKey: key) == "/custom/config.json")
    }
}

private struct AssetFixture {
    let root: URL

    init() throws {
        root = URL.temporaryDirectory.appendingPathComponent("native-documents-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func asset(_ name: String, xcodeVersion: String, release: Any, osVersion: String = "27.0") throws -> URL {
        let asset = root.appendingPathComponent("\(name).asset", isDirectory: true)
        let data = asset.appendingPathComponent("AssetData", isDirectory: true)
        try FileManager.default.createDirectory(
            at: data.appendingPathComponent("documentation-db", isDirectory: true), withIntermediateDirectories: true)
        let info: [String: Any] = ["MobileAssetProperties": [
            "XcodeVersion": xcodeVersion, "DocumentationRelease": release, "OSVersion": osVersion,
        ]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: asset.appendingPathComponent("Info.plist"))
        let config = data.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)
        try Data().write(to: data.appendingPathComponent("documentation-db/index.sql"))
        return config
    }
}

private func sameFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
    let left = try lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    let right = try rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    return left?.isEqual(right) == true
}
