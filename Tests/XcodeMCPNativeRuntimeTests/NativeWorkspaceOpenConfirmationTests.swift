import AppKit
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@MainActor
@Suite(.serialized)
struct NativeWorkspaceOpenConfirmationTests {
    init() throws {
        // Configure the shared application before any test enters a modal loop,
        // matching the native host's bootstrap order.
        try NativeErrorPresentation.install(on: NSApplication.shared)
    }

    @Test func anErrorInsideAWorkspaceConfirmationDoesNotOpenAnotherModalPanel() {
        let application = NSApplication.shared
        let confirmation = NativeWorkspaceOpenConfirmation(application: application)
        defer { withExtendedLifetime(confirmation) {} }
        let alert = NSAlert()
        alert.messageText =
            "“App.xcodeproj” appears to be open in another running Xcode process. Do you want to open it in this Xcode?"
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Cancel")
        var recovered: Bool?
        let error = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                recovered = application.presentError(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue))
            }
        }
        RunLoop.main.add(error, forMode: .modalPanel)
        defer { error.invalidate() }
        #expect(runModal(alert, application: application, timeout: 3) == .alertFirstButtonReturn)
        #expect(recovered == false)
    }

    @Test func opensRepeatedWorkspaceConfirmationsInTheModalRunLoop() {
        let application = NSApplication.shared
        let confirmation = NativeWorkspaceOpenConfirmation(application: application)
        defer { withExtendedLifetime(confirmation) {} }

        for name in ["Package.xcworkspace", "App.xcodeproj"] {
            let alert = NSAlert()
            alert.messageText =
                "“\(name)” appears to be open in another running Xcode process. Do you want to open it in this Xcode?"
            alert.addButton(withTitle: "Open Anyway")
            alert.addButton(withTitle: "Cancel")
            #expect(runModal(alert, application: application, timeout: 3) == .alertFirstButtonReturn)
        }
    }

    @Test(arguments: [
        ("Allow “Client” to access Xcode?", "Allow"),
        ("Open an existing document?", "Open Anyway"),
    ])
    func leavesOtherConfirmationsUntouched(message: String, button: String) {
        let application = NSApplication.shared
        let confirmation = NativeWorkspaceOpenConfirmation(application: application)
        defer { withExtendedLifetime(confirmation) {} }

        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        #expect(runModal(alert, application: application, timeout: 0.5) == .abort)
    }

    private func runModal(
        _ alert: NSAlert,
        application: NSApplication,
        timeout: TimeInterval
    ) -> NSApplication.ModalResponse {
        let watchdog = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                application.stopModal(withCode: .abort)
            }
        }
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer {
            watchdog.invalidate()
            alert.window.orderOut(nil)
            // Ending a modal session can leave a stop request for the main run loop. The native
            // host runs NSApplication's event loop, where it only ends one iteration, but here the
            // main run loop belongs to the test executor, and stopping it ends the test process.
            // A nested pass runs the queued request so that it stops only that pass.
            CFRunLoopRunInMode(.defaultMode, 0, false)
        }
        return alert.runModal()
    }
}
