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
        UserDefaults.standard.addSuite(named: "com.apple.dt.Xcode")
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
        let shared = try runtime.object(applicationClass as AnyObject).method(selector: "sharedApplication", as: (() -> NSApplication).self)
        let application = try unsafe shared.unsafeInvoke()
        let createController = try runtime.object(controllerClass as AnyObject).method(selector: "new", as: (() -> AnyObject).self)
        documentController = try unsafe createController.unsafeInvoke()
        application.setActivationPolicy(.prohibited)
        workspaceOpenConfirmation = NativeWorkspaceOpenConfirmation(application: application)
        return application
    }

    package func initialize(installation: NativeXcodeInstallation) async throws {
        let initialize = try unsafe await ABIRuntime.shared.cFunction(named: "IDEInitialize", as: ((UInt64, UnsafeMutableRawPointer?) -> Bool).self,
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
