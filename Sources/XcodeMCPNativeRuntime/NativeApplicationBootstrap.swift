import ABIBridge
import AppKit
import Foundation

@MainActor
package final class NativeApplicationBootstrap {
    private var documentController: AnyObject?
    private var kitBundle: Bundle?
    private var workspaceOpenConfirmation: NativeWorkspaceOpenConfirmation?

    package init() {}

    package func application(for installation: NativeXcodeInstallation) throws -> NSApplication {
        let defaults = UserDefaults.standard
        defaults.addSuite(named: "com.apple.dt.Xcode")
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let buildSettingsKey = "IDEApplicationwideBuildSettings"
        arguments[buildSettingsKey] = Self.compilationCacheSettings(
            existing: defaults.dictionary(forKey: buildSettingsKey) ?? [:],
            environment: ProcessInfo.processInfo.environment)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        // Configure the installed index before Xcode initializes its chat settings.
        // The downloadable-asset coordinator can have no location in a headless host.
        do {
            if try NativeDocumentationSearchAsset.configureLatest() == nil {
                try? FileHandle.standardError.write(contentsOf: Data("DocumentationSearch: no installed documentation index found\n".utf8))
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("DocumentationSearch asset discovery failed: \(error)\n".utf8))
        }
        do {
            _ = try NativeMetalToolchain.configure(for: installation)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Metal Toolchain discovery failed: \(error)\n".utf8))
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
        let shared = try runtime.object(applicationClass as AnyObject).resolveMethodAndWait(selector: "sharedApplication", as: (() -> NSApplication).self)
        let application = try unsafe shared.unsafeInvoke()
        let createController = try runtime.object(controllerClass as AnyObject).resolveMethodAndWait(selector: "new", as: (() -> AnyObject).self)
        documentController = try unsafe createController.unsafeInvoke()
        application.setActivationPolicy(.prohibited)
        try NativeErrorPresentation.install(on: application)
        workspaceOpenConfirmation = NativeWorkspaceOpenConfirmation(application: application)
        return application
    }

    static func compilationCacheSettings(existing: [String: Any], environment: [String: String]) -> [String: Any] {
        var settings = existing
        // IDE builds sanitize their build-setting environment. Supply defaults through
        // the application's build table, inheriting each project's explicit setting.
        for key in [
            "COMPILATION_CACHE_ENABLE_CACHING_DEFAULT",
            "SWIFT_ENABLE_PREFIX_MAPPING", "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING",
            "CLANG_ENABLE_PREFIX_MAPPING", "CLANG_ENABLE_PROJECT_PREFIX_MAPPING",
        ] where settings[key] == nil {
            settings[key] = "$(inherited:default=\(environment[key] ?? "YES"))"
        }
        return settings
    }

    package func initialize(installation: NativeXcodeInstallation) async throws {
        let initialize = try unsafe await ABIRuntime.shared.resolveCFunction(named: "IDEInitialize", as: ((UInt64, UnsafeMutableRawPointer?) -> Bool).self,
                                                             in: .path(installation.framework("IDEFoundation")), loading: .loadedOnly)
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
