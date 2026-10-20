import Foundation
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime

func makeConfig(requestTimeout: TimeInterval) -> ProxyRuntimeConfiguration {
    ProxyRuntimeConfiguration(
        maxMessageBytes: 1024,
        requestTimeout: requestTimeout,
        prewarmToolsList: false
    )
}

func makeBridgeRuntimeConfig(
    _ config: ProxyRuntimeConfiguration
) throws -> NativeHostRuntime.Configuration {
    try NativeHostRuntime.Configuration(
        nativeHostBundleURL: nativeHostBundleURLForTests(), developerDirectoryURL: config.developerDirectoryURL,
        sharesCompilationCache: config.sharesCompilationCache, maxBodyBytes: config.maxMessageBytes)
}

private let nativeHostBundleFixture = NIOLockedValueBox<URL?>(nil)

func nativeHostBundleURLForTests() throws -> URL {
    try nativeHostBundleFixture.withLockedValue { value in
        if let value { return value }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("NativeHostRuntimeTests-" + UUID().uuidString + ".app")
        let contents = bundle.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("xcode-mcp-native-host")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.XcodeMCPNativeHost", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "xcode-mcp-native-host",
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        value = bundle
        return bundle
    }
}

func makeDeterministicClocks() -> (clock: ClockClient, timeoutClock: TestClock, uptimeClock: TestUptimeClock) {
    let timeoutClock = TestClock()
    let uptimeClock = TestUptimeClock()
    let clock = ClockClient(
        now: { Date(timeIntervalSince1970: Double(uptimeClock.now()) / 1_000_000_000) },
        uptimeNanoseconds: uptimeClock.now,
        sleep: { duration in try? await timeoutClock.sleep(for: duration) },
        sleepForTimeInterval: { _ in })
    return (clock, timeoutClock, uptimeClock)
}
