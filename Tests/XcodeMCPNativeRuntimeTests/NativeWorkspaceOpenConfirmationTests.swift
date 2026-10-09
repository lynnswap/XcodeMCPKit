import AppKit
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@MainActor
@Suite(.serialized)
struct NativeWorkspaceOpenConfirmationTests {
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
        defer { watchdog.invalidate(); alert.window.orderOut(nil) }
        return alert.runModal()
    }
}
