import AppKit
import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@MainActor
extension NativeWorkspaceOpenConfirmationTests {
    @Test func applicationErrorsReturnWithoutPresentingAModalPanel() throws {
        let application = NSApplication.shared
        try NativeErrorPresentation.install(on: application)
        let observation = application.observe(\.isActive) { _, _ in }
        defer { observation.invalidate() }
        try NativeErrorPresentation.install(on: application)
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue,
                            userInfo: [NSFilePathErrorKey: "/removed/App.xcodeproj"])
        let capture = NativeErrorPresentation.Capture()

        NativeErrorPresentation.$capture.withValue(capture) {
            #expect(!application.presentError(error))
        }

        #expect(capture.errors == [error])
        #expect(application.modalWindow == nil)
        #expect(capture.errors.first?.userInfo[NSFilePathErrorKey] as? String == "/removed/App.xcodeproj")
    }

    @Test func sheetErrorsCompleteTheirDelegateWithTheOriginalContext() throws {
        let application = NSApplication.shared
        try NativeErrorPresentation.install(on: application)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let delegate = ErrorPresentationDelegate()
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        let capture = NativeErrorPresentation.Capture()
        var marker = 0
        withUnsafeMutablePointer(to: &marker) { pointer in
            let context = UnsafeMutableRawPointer(pointer)
            NativeErrorPresentation.$capture.withValue(capture) {
                unsafe application.presentError(
                    error, modalFor: window, delegate: delegate,
                    didPresent: #selector(ErrorPresentationDelegate.didPresentError(_:contextInfo:)),
                    contextInfo: context
                )
            }
            #expect(delegate.recovered == false)
            #expect(delegate.contextAddress == UInt(bitPattern: context))
        }
        #expect(delegate.calls == 1)
        #expect(capture.errors == [error])
        #expect(!window.isVisible)
        #expect(application.modalWindow == nil)
    }

}

@MainActor
struct NativeErrorPresentationTests {
    @Test func backgroundErrorsDoNotContaminateAnOperationCapture() {
        let capture = NativeErrorPresentation.Capture()
        NativeErrorPresentation.$capture.withValue(capture) {
            NativeErrorPresentation.$capture.withValue(nil) {
                NativeErrorPresentation.report(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue))
            }
        }
        #expect(capture.errors.isEmpty)
    }
}

@MainActor
private final class ErrorPresentationDelegate: NSObject {
    private(set) var calls = 0
    private(set) var recovered: Bool?
    private(set) var contextAddress: UInt?

    @objc func didPresentError(_ recovered: Bool, contextInfo: UnsafeMutableRawPointer?) {
        calls += 1
        self.recovered = recovered
        contextAddress = unsafe contextInfo.map { UInt(bitPattern: $0) }
    }
}
