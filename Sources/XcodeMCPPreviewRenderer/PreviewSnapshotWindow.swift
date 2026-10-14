#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import Foundation
import UIKit

@MainActor
final class PreviewSnapshotWindow {
    private static let identifierPrefix = "XcodeMCPPreviewRenderer.Snapshot."
    let window: UIWindow
    private let invalidateScene: () throws -> Void
    private let removeSession: () throws -> Void
    private let invalidateNativeScene: () async throws -> Void

    private init(window: UIWindow,
                 invalidateScene: @escaping () throws -> Void,
                 removeSession: @escaping () throws -> Void,
                 invalidateNativeScene: @escaping () async throws -> Void) {
        self.window = window
        self.invalidateScene = invalidateScene
        self.removeSession = removeSession
        self.invalidateNativeScene = invalidateNativeScene
    }

    static func configuration(for session: UISceneSession) -> UISceneConfiguration? {
        guard session.persistentIdentifier.hasPrefix(identifierPrefix) else { return nil }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = PreviewSnapshotScene.self
        return configuration
    }

    static func withWindow<Output>(from original: UIWindow, orientation: UIInterfaceOrientation,
                                   perform operation: (UIWindow) async throws -> Output) async throws -> Output {
        let owner: PreviewSnapshotWindow
        do { owner = try await connect(from: original, orientation: orientation) }
        catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
        let output: Output
        do { output = try await operation(owner.window) }
        catch {
            let operationError = error
            do { try await owner.close() }
            catch { throw PreviewRendererError("\(operationError); snapshot scene cleanup also failed: \(error)") }
            throw operationError
        }
        try await owner.close()
        return output
    }

    private static func connect(from originalWindow: UIWindow, orientation: UIInterfaceOrientation) async throws -> PreviewSnapshotWindow {
        let runtime = ABIRuntime.shared
        guard let originalScene = originalWindow.windowScene,
              let originalFBS = try await object(originalScene, "_FBSScene"),
              let originalSettings = try await object(originalFBS, "settings"),
              let specification = try await object(originalFBS, "specification"),
              let displayConfiguration = try await object(originalSettings, "displayConfiguration"),
              let fbsClass = NSClassFromString("FBSScene") else { throw NativePreviewPipelineRequired() }
        let edgeSymbol = try await runtime.resolve(.init(machOName: "_OBJC_CLASS_$_UISApplicationSupportDisplayEdgeInfo",
            language: .objectiveC, kind: .data), in: .framework(named: "UIKitServices"))
        guard let edgeClass = NSClassFromString("UISApplicationSupportDisplayEdgeInfo") else { throw NativePreviewPipelineRequired() }
        let factory = try await runtime.object(fbsClass as AnyObject).resolveMethod(
            selector: "pseudoSceneWithIdentifier:specification:", as: ((String, AnyObject) -> AnyObject).self)
        let connect = try await runtime.object(UIApplication.shared).resolveMethod(
            selector: "_connectUISceneFromFBSScene:transitionContext:", as: ((AnyObject, AnyObject?) -> AnyObject?).self)
        let invalidateUI = try await runtime.resolveObjCMethod(on: UIWindowScene.self, selector: "_invalidate", as: (() -> Void).self)
        let remove = try await runtime.object(UIApplication.shared).resolveMethod(
            selector: "_removeSessionFromSessionSet:", as: ((UISceneSession) -> Void).self)
        let identifier = identifierPrefix + UUID().uuidString
        let nativeScene = try unsafe factory.unsafeInvoke(identifier, specification)
        guard let queue = try await object(nativeScene, "callOutQueue") else { throw NativePreviewPipelineRequired() }
        typealias QueueAction = @convention(block) () -> Void
        let enqueue = try await runtime.object(queue).resolveMethod(selector: "performAsync:", as: ((@escaping QueueAction) -> Void).self)
        let invalidate = try await runtime.object(nativeScene).resolveMethod(selector: "invalidate", as: (() -> Void).self)
        let invalidateNative = {
            // The native updater requires its own call-out queue barrier. This
            // factory cannot create an agent, so invalidation finishes in this block.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let action: QueueAction = {
                    do { try unsafe invalidate.unsafeInvoke(); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
                do { try unsafe enqueue.unsafeInvoke(action) }
                catch { continuation.resume(throwing: error) }
            }
        }
        var connectedScene: UIWindowScene?
        do {
            guard let settings = try await object(nativeScene, "settings"),
                  let mutable = try await object(settings, "mutableCopy") else { throw NativePreviewPipelineRequired() }
            let edgeFactory = try await runtime.object(edgeClass as AnyObject).resolveMethod(
                selector: "defaultDisplayEdgeInfoForceInsets:", as: ((Bool) -> AnyObject).self)
            let edge = try unsafe edgeFactory.unsafeInvoke(true)
            let portraitInsets = try await insets(edge, "safeAreaInsetsPortrait")
            let peripheryInsets = try await insets(edge, "peripheryInsets")
            let home = try await object(edge, "homeAffordanceOverlayAllowance") as? NSNumber
            let settingsClass: AnyClass = type(of: mutable)
            let frame = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setFrame:", as: ((CGRect) -> Void).self)
            let interface = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setInterfaceOrientation:", as: ((Int64) -> Void).self)
            let mode = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setInterfaceOrientationMode:", as: ((Int64) -> Void).self)
            let device = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setDeviceOrientation:", as: ((Int64) -> Void).self)
            let display = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setDisplayConfiguration:", as: ((AnyObject) -> Void).self)
            let portrait = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setSafeAreaInsetsPortrait:", as: ((UIEdgeInsets) -> Void).self)
            let periphery = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setPeripheryInsets:", as: ((UIEdgeInsets) -> Void).self)
            let homeAllowance = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setHomeAffordanceOverlayAllowance:", as: ((Double) -> Void).self)
            let statusHeight = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setDefaultStatusBarHeight:forOrientation:", as: ((Double, Int64) -> Void).self)
            let persistence = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setPersistenceIdentifier:", as: ((String) -> Void).self)
            let foreground = try await runtime.resolveObjCMethod(on: settingsClass, selector: "setForeground:", as: ((Bool) -> Void).self)
            let readHeight = try await runtime.object(originalSettings).resolveMethod(selector: "defaultStatusBarHeightForOrientation:", as: ((Int64) -> Double).self)
            let heights = try [UIInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].map {
                (Int64($0.rawValue), try unsafe readHeight.unsafeInvoke(Int64($0.rawValue)))
            }
            let deviceOrientation: UIDeviceOrientation
            switch orientation {
            case .portrait: deviceOrientation = .portrait
            case .portraitUpsideDown: deviceOrientation = .portraitUpsideDown
            case .landscapeLeft: deviceOrientation = .landscapeRight
            case .landscapeRight: deviceOrientation = .landscapeLeft
            default: throw NativePreviewPipelineRequired()
            }
            let screenSize = originalWindow.screen.fixedCoordinateSpace.bounds.size
            // FBS settings bounds rotate this reference frame for the requested
            // orientation; rotating the frame here would rotate the size twice.
            let referenceFrame = CGRect(origin: .zero, size: screenSize)
            typealias SettingsAction = @convention(block) (AnyObject, AnyObject) -> Void
            let update = try await runtime.object(nativeScene).resolveMethod(selector: "updateSettings:", as: ((@escaping SettingsAction) -> Void).self)
            var transition: AnyObject?
            var updateError: (any Error)?
            let configure: SettingsAction = { settings, context in
                MainActor.assumeIsolated {
                    do {
                        transition = context
                        try unsafe frame.unsafeInvoke(on: settings, referenceFrame)
                        try unsafe interface.unsafeInvoke(on: settings, Int64(orientation.rawValue))
                        // PreviewShell.SceneConfigurator passes mode 2 on iOS 27.2.
                        try unsafe mode.unsafeInvoke(on: settings, 2)
                        try unsafe device.unsafeInvoke(on: settings, Int64(deviceOrientation.rawValue))
                        try unsafe display.unsafeInvoke(on: settings, displayConfiguration)
                        try unsafe portrait.unsafeInvoke(on: settings, portraitInsets)
                        try unsafe periphery.unsafeInvoke(on: settings, peripheryInsets)
                        try unsafe homeAllowance.unsafeInvoke(on: settings, home?.doubleValue ?? 0)
                        for (orientation, height) in heights { try unsafe statusHeight.unsafeInvoke(on: settings, height, orientation) }
                        try unsafe persistence.unsafeInvoke(on: settings, identifier)
                        try unsafe foreground.unsafeInvoke(on: settings, true)
                    } catch { updateError = error }
                }
            }
            try unsafe update.unsafeInvoke(configure)
            if let updateError { throw updateError }
            guard let scene = try unsafe connect.unsafeInvoke(nativeScene, transition) as? UIWindowScene else { throw NativePreviewPipelineRequired() }
            connectedScene = scene
            let window = UIWindow(windowScene: scene)
            let session = scene.session
            return withExtendedLifetime(edgeSymbol) {
                PreviewSnapshotWindow(window: window,
                    invalidateScene: { try unsafe invalidateUI.unsafeInvoke(on: scene) },
                    removeSession: { try unsafe remove.unsafeInvoke(session) }, invalidateNativeScene: invalidateNative)
            }
        } catch {
            let operationError = error
            do {
                let session = connectedScene?.session ?? UIApplication.shared.openSessions.first { $0.persistentIdentifier == identifier }
                let scene = connectedScene ?? session?.scene as? UIWindowScene
                try await finishCleanup(
                    invalidateScene: { if let scene { try unsafe invalidateUI.unsafeInvoke(on: scene) } },
                    removeSession: { if let session { try unsafe remove.unsafeInvoke(session) } },
                    invalidateNativeScene: invalidateNative)
            } catch { throw PreviewRendererError("\(operationError); snapshot scene cleanup also failed: \(error)") }
            throw operationError
        }
    }

    private func close() async throws {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        try await Self.finishCleanup(invalidateScene: invalidateScene, removeSession: removeSession,
                                     invalidateNativeScene: invalidateNativeScene)
    }

    private static func finishCleanup(invalidateScene: () throws -> Void, removeSession: () throws -> Void,
                                      invalidateNativeScene: () async throws -> Void) async throws {
        var failures: [any Error] = []
        do { try invalidateScene() } catch { failures.append(error) }
        do { try removeSession() } catch { failures.append(error) }
        do { try await invalidateNativeScene() } catch { failures.append(error) }
        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty {
            throw PreviewRendererError(failures.map { String(describing: $0) }.joined(separator: "; "))
        }
    }

    private static func object(_ owner: AnyObject, _ selector: String) async throws -> AnyObject? {
        let getter = try await ABIRuntime.shared.object(owner).resolveMethod(selector: selector, as: (() -> AnyObject?).self)
        return try unsafe getter.unsafeInvoke()
    }

    private static func insets(_ edge: AnyObject, _ name: String) async throws -> UIEdgeInsets {
        guard let wrapper = try await object(edge, name) else { return .zero }
        var values: [Double] = []
        for field in ["topInset", "leftInset", "bottomInset", "rightInset"] {
            let getter = try await ABIRuntime.shared.object(wrapper).resolveMethod(selector: field, as: (() -> Double).self)
            values.append(try unsafe getter.unsafeInvoke())
        }
        return UIEdgeInsets(top: values[0], left: values[1], bottom: values[2], right: values[3])
    }
}

@MainActor
private final class PreviewSnapshotScene: UIResponder, UIWindowSceneDelegate {
    @available(iOS 27.0, *)
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask { .all }
}
#endif
