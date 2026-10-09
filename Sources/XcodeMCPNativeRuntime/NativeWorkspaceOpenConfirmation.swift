import AppKit
import Foundation

@MainActor
final class NativeWorkspaceOpenConfirmation {
    private let timer: Timer

    init(application: NSApplication) {
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak application] _ in
            MainActor.assumeIsolated {
                guard let window = application?.modalWindow,
                      let button = Self.openAnywayButton(in: window) else { return }
                button.performClick(nil)
            }
        }
        // Keep responding in the nested modal loop used by workspace loading,
        // even when the host cannot activate its confirmation window.
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    isolated deinit {
        timer.invalidate()
    }

    private static func openAnywayButton(in window: NSWindow) -> NSButton? {
        guard let contentView = window.contentView else { return nil }
        let views = descendants(of: contentView)
        // Xcode's workspace-claim alert uses this literal English message.
        // Match it before choosing a button so other alerts keep their behavior.
        let messageSuffix =
            " appears to be open in another running Xcode process. Do you want to open it in this Xcode?"
        guard views.contains(where: {
            ($0 as? NSTextField)?.stringValue.hasSuffix(messageSuffix) == true
        }) else { return nil }
        return views.compactMap { $0 as? NSButton }.first {
            $0.title == "Open Anyway" && $0.isEnabled
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
