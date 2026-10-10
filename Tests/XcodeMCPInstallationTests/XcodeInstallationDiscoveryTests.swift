import Foundation
import Testing
@testable import XcodeMCPInstallation

@Suite
struct XcodeInstallationDiscoveryTests {
    @Test func commandLineToolsSelectionUsesTheNewestInstalledXcode() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let older = try fixture.xcode("Older.app", version: "27.9")
        let newer = try fixture.xcode("Renamed IDE.app", version: "27.10")
        let discovery = fixture.discovery(selected: fixture.root.appending(path: "CommandLineTools"), registered: [older, newer])
        #expect(try discovery.resolve(environment: [:]).appURL.path == newer.path)
        #expect(discovery.discover().map { $0.appURL.path } == [newer.path, older.path])
    }

    @Test func validSelectionsTakePrecedenceOverDiscovery() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let explicit = try fixture.xcode("Explicit.app", version: "27.1")
        let environment = try fixture.xcode("Environment.app", version: "27.2")
        let selected = try fixture.xcode("Selected.app", version: "27.3")
        let newest = try fixture.xcode("Newest.app", version: "27.4")
        let discovery = fixture.discovery(selected: selected, registered: [newest])
        #expect(try discovery.resolve(preferred: explicit, environment: ["DEVELOPER_DIR": environment.path]).appURL.path == explicit.path)
        #expect(try discovery.resolve(environment: ["DEVELOPER_DIR": environment.path]).appURL.path == environment.path)
        #expect(try discovery.resolve(environment: [:]).appURL.path == selected.path)
    }

    @Test(arguments: ["", " \t\n", "/missing/Xcode.app", "/Library/Developer/CommandLineTools"])
    func unavailableEnvironmentSelectionsDoNotHideInstalledXcode(value: String) throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let app = try fixture.xcode("Available.app")
        let discovery = fixture.discovery(registered: [app])
        #expect(try discovery.resolve(environment: ["DEVELOPER_DIR": value]).appURL.path == app.path)
    }

    @Test func unavailableExplicitSelectionUsesAValidEnvironmentSelection() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let app = try fixture.xcode("Available.app")
        let discovery = fixture.discovery()
        #expect(try discovery.resolve(preferred: fixture.root.appending(path: "Removed.app"),
                                     environment: ["DEVELOPER_DIR": app.path]).appURL.path == app.path)
    }

    @Test func registeredHostDoesNotSwitchInstallationsAfterItsXcodeIsRemoved() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let registered = try fixture.xcode("Registered.app")
        let other = try fixture.xcode("Other.app", version: "27.1")
        let discovery = fixture.discovery(selected: other, registered: [registered, other])
        let selection = try discovery.resolve(preferred: registered, environment: [:])
        try FileManager.default.removeItem(at: registered)
        #expect(throws: XcodeInstallationDiscoveryError.self) {
            _ = try discovery.resolve(required: selection.developerDirectory, environment: ["DEVELOPER_DIR": other.path])
        }
    }

    @Test func xcodeSelectChildReadsTheSystemPreferenceWithoutAnEnvironmentOverride() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let command = fixture.root.appending(path: "xcode-select")
        try Data("#!/bin/sh\nprintf '%s\\n' \"\u{24}{DEVELOPER_DIR:-/Fixture/System.app/Contents/Developer}\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let selected = try XcodeInstallationDiscovery.systemDeveloperDirectory(
            environment: ["DEVELOPER_DIR": "/Library/Developer/CommandLineTools"], executableURL: command
        )
        #expect(selected?.path == "/Fixture/System.app/Contents/Developer")
    }

    @Test func failedXcodeSelectDoesNotPreventMetadataDiscovery() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let app = try fixture.xcode("Custom Location/Developer Tools.app")
        var discovery = fixture.discovery(metadata: [app])
        discovery.selectedDeveloperDirectory = { throw XcodeInstallationDiscoveryError("No selected developer directory") }
        #expect(try discovery.resolve(environment: [:]).appURL.path == app.path)
    }

    @Test func unregisteredApplicationsAreFoundWithoutSpotlight() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let app = try fixture.xcode("Applications/Developer Tools/Custom IDE.app")
        var discovery = fixture.discovery(applicationDirectories: [fixture.root.appending(path: "Applications")])
        discovery.metadataApplications = { throw XcodeInstallationDiscoveryError("Spotlight is unavailable") }
        #expect(try discovery.resolve(environment: [:]).appURL.path == app.path)
    }

    @Test(arguments: ["PlugIns/IDEIntelligenceChat.framework", "PlugIns/IDEIntelligenceMessaging.framework"])
    func staleAndUnsupportedCandidatesAreSkipped(missingFramework: String) throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let incomplete = try fixture.xcode("Incomplete.app", version: "99.0")
        try FileManager.default.removeItem(at: incomplete.appending(path: "Contents/\(missingFramework)"))
        let future = try fixture.xcode("Future.app", version: "99.1", minimumSystemVersion: "28.0")
        let usable = try fixture.xcode("Available.app", version: "27.1")
        let stale = fixture.root.appending(path: "Removed.app")
        let discovery = fixture.discovery(selected: stale, registered: [stale, incomplete, future, usable])
        #expect(try discovery.resolve(environment: [:]).appURL.path == usable.path)
        #expect(discovery.discover().map { $0.appURL.path } == [usable.path])
    }

    @Test func applicationAndDeveloperPathsAndSymlinksHaveOneIdentity() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let app = try fixture.xcode("Custom Location/Selected IDE.app")
        let developer = app.appending(path: "Contents/Developer")
        let link = fixture.root.appending(path: "Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let discovery = fixture.discovery(registered: [app, developer, link], metadata: [app])
        #expect(discovery.discover().count == 1)
        for input in [app, developer, link, URL(fileURLWithPath: app.path + "/")] {
            #expect(try discovery.resolve(preferred: input, environment: [:]).developerDirectory.path == developer.path)
        }
    }

    @Test func equalVersionsHaveAStableSelectionIndependentOfInventoryOrder() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let first = try fixture.xcode("First.app")
        let second = try fixture.xcode("Second.app")
        #expect(try fixture.discovery(registered: [second, first]).resolve(environment: [:]).appURL.path == first.path)
        #expect(try fixture.discovery(registered: [first, second]).resolve(environment: [:]).appURL.path == first.path)
    }

    @Test func emptyDiscoveryReportsAnActionableFailure() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let discovery = fixture.discovery(selected: fixture.root.appending(path: "CommandLineTools"))
        do {
            _ = try discovery.resolve(environment: [:])
            Issue.record("expected installation discovery to fail")
        } catch let error as XcodeInstallationDiscoveryError {
            #expect(error.description.contains("No available Xcode installation"))
            #expect(error.description.contains("DEVELOPER_DIR"))
            #expect(error.description.contains("CommandLineTools"))
        }
    }
}

private struct InstallationFixture {
    let root: URL

    init() throws {
        root = URL.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func xcode(_ name: String, version: String = "27.0", minimumSystemVersion: String = "15.4") throws -> URL {
        let app = root.appending(path: name)
        let contents = app.appending(path: "Contents")
        for path in [
            "Developer", "Frameworks/IDEFoundation.framework", "Frameworks/IDEKit.framework",
            "SharedFrameworks/DVTFoundation.framework", "PlugIns/IDEIntelligenceChat.framework",
            "PlugIns/IDEIntelligenceMessaging.framework",
        ] {
            try FileManager.default.createDirectory(at: contents.appending(path: path), withIntermediateDirectories: true)
        }
        let info = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": version, "LSMinimumSystemVersion": minimumSystemVersion]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return app
    }

    func discovery(selected: URL? = nil, registered: [URL] = [], metadata: [URL] = [],
                   applicationDirectories: [URL] = []) -> XcodeInstallationDiscovery {
        XcodeInstallationDiscovery(selectedDeveloperDirectory: { selected }, registeredApplications: { registered },
            metadataApplications: { metadata }, applicationDirectories: applicationDirectories,
            systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }
}
