import ABIBridge
import AppKit
import Foundation

@MainActor
package final class NativeApplicationBootstrap {
    private var documentController: AnyObject?
    private var kitBundle: Bundle?
    private var workspaceOpenConfirmation: NativeWorkspaceOpenConfirmation?

    package init() {}

    package func application(for installation: NativeXcodeInstallation, sharesCompilationCache: Bool = false) throws -> NSApplication {
        let defaults = UserDefaults.standard
        defaults.addSuite(named: "com.apple.dt.Xcode")
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // Xcode's SCM service accepts Apple-signed clients. SwiftPM's built-in
        // provider uses system Git while retaining the native package workspace.
        arguments["IDEPackageSupportUseBuiltinSCM"] = true
        if sharesCompilationCache {
            let buildSettingsKey = "IDEApplicationwideBuildSettings"
            arguments[buildSettingsKey] = Self.compilationCacheSettings(
                existing: defaults.dictionary(forKey: buildSettingsKey) ?? [:],
                environment: ProcessInfo.processInfo.environment)
        }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        // Configure the installed index before Xcode initializes its chat settings.
        // The downloadable-asset coordinator can have no location in a headless host.
        do {
            if try NativeDocumentationSearchAsset.configureLatest() == nil {
                NativeHostDiagnostic.report("DocumentationSearch: no installed documentation index found", level: .warning)
            }
        } catch {
            NativeHostDiagnostic.report("DocumentationSearch asset discovery failed: \(error)")
        }
        do {
            _ = try NativeMetalToolchain.configure(for: installation)
        } catch {
            NativeHostDiagnostic.report("Metal Toolchain discovery failed: \(error)")
        }
        let framework = installation.contentsDirectory.appendingPathComponent("Frameworks/IDEKit.framework")
        guard let bundle = Bundle(url: framework) else {
            throw NativeRuntimeError.unavailable("Cannot locate IDEKit at \(framework.path)")
        }
        try bundle.loadAndReturnError()
        kitBundle = bundle
        guard let applicationClass = NSClassFromString("IDEApplication"),
              let controllerClass = NSClassFromString("IDEDocumentController") else {
            throw NativeRuntimeError.unavailable("Xcode native application classes are unavailable")
        }
        let runtime = ABIRuntime.shared
        let shared = try runtime.object(applicationClass as AnyObject).resolveAndWait(.objc(.method("sharedApplication", as: (() -> NSApplication).self)))
        let application = try unsafe shared.unsafeInvoke()
        let createController = try runtime.object(controllerClass as AnyObject).resolveAndWait(.objc(.method("new", as: (() -> AnyObject).self)))
        documentController = try unsafe createController.unsafeInvoke()
        application.setActivationPolicy(.prohibited)
        try NativeErrorPresentation.install(on: application)
        workspaceOpenConfirmation = NativeWorkspaceOpenConfirmation(application: application)
        return application
    }

    static func compilationCacheSettings(existing: [String: Any], environment: [String: String]) -> [String: Any] {
        var settings = existing
        // Xcode's coverage reader needs real source paths.
        let prefixDefault = "$(XCODE_MCPKIT_PREFIX_MAPPING_FOR_COVERAGE_$(CLANG_COVERAGE_MAPPING):default=YES)"
        // Swift #92545 crashes cached diagnostic replay for mixed mapped/unmapped
        // inputs with multiple primaries. Single-file jobs preserve cache reuse.
        let batchDefault = "$(XCODE_MCPKIT_BATCH_MODE_$(SWIFT_ENABLE_COMPILE_CACHE)_$(SWIFT_ENABLE_PREFIX_MAPPING):default=YES)"
        let projectPrefixDefault = "$(XCODE_MCPKIT_PROJECT_PREFIX_FOR_BATCH_$(SWIFT_ENABLE_BATCH_MODE):default=YES)"
        let values = [
            "COMPILATION_CACHE_ENABLE_CACHING_DEFAULT": "YES",
            "SWIFT_ENABLE_PREFIX_MAPPING": prefixDefault,
            "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING": projectPrefixDefault,
            "CLANG_ENABLE_PREFIX_MAPPING": prefixDefault,
            "CLANG_ENABLE_PROJECT_PREFIX_MAPPING": "YES",
        ]
        // IDE builds sanitize their build-setting environment. Supply defaults through
        // the application's build table, inheriting each project's explicit setting.
        for (key, value) in values where settings[key] == nil {
            settings[key] = "$(inherited:default=\(environment[key] ?? value))"
        }
        for (key, value) in [
            "XCODE_MCPKIT_PREFIX_MAPPING_FOR_COVERAGE_YES": "NO",
            "XCODE_MCPKIT_BATCH_MODE_YES_YES": "NO",
            "XCODE_MCPKIT_PROJECT_PREFIX_FOR_BATCH_YES": "NO",
            // App-wide settings already sit below project and target settings.
            // Inheriting Xcode's built-in YES here would bypass the compiler workaround.
            "SWIFT_ENABLE_BATCH_MODE": environment["SWIFT_ENABLE_BATCH_MODE"] ?? batchDefault,
        ] where settings[key] == nil {
            settings[key] = value
        }
        return settings
    }

    package func initialize(installation: NativeXcodeInstallation) async throws {
        let initialize = try unsafe await ABIRuntime.shared.resolve(
            .c(.function("IDEInitialize", as: ((UInt64, UnsafeMutableRawPointer?) -> Bool).self)), in: .path(installation.framework("IDEFoundation")),
            loading: .loadedOnly)
        var errorAddress: UnsafeRawPointer?
        let initialized = try withUnsafeMutablePointer(to: &errorAddress) {
            try unsafe initialize.unsafeInvoke(7, UnsafeMutableRawPointer($0))
        }
        guard initialized else {
            if let errorAddress = unsafe errorAddress { throw unsafe Unmanaged<NSError>.fromOpaque(errorAddress).takeUnretainedValue() }
            throw NativeRuntimeError.unavailable("Xcode native initialization failed without an error")
        }
    }
}
