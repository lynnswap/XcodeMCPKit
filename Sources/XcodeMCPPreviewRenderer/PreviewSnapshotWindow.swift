#if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
import ABIBridge
import Foundation
import UIKit

@MainActor
final class PreviewSnapshotWindow {
    private enum Geometry {
        #if os(iOS)
        case display(orientation: UIInterfaceOrientation)
        #else
        case custom(size: CGSize)
        #endif
    }

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

    #if os(iOS)
    static func open(from original: UIWindow, orientation: UIInterfaceOrientation) async throws -> PreviewSnapshotWindow {
        try await open(from: original, geometry: .display(orientation: orientation))
    }
    #else
    static func open(from original: UIWindow, size: CGSize) async throws -> PreviewSnapshotWindow {
        try await open(from: original, geometry: .custom(size: size))
    }

    func resize(to size: CGSize) async throws {
        do {
            guard let scene = window.windowScene,
                  let native = try await Self.object(scene, "_FBSScene"),
                  let settings = try await Self.object(native, "settings"),
                  let mutable = try await Self.object(settings, "mutableCopy") else { throw NativePreviewPipelineRequired() }
            let runtime = ABIRuntime.shared
            let frame = try await runtime.resolve(.objc(.method("setFrame:", as: ((CGRect) -> Void).self)), on: type(of: mutable))
            typealias SettingsAction = @convention(block) (AnyObject, AnyObject) -> Void
            let update = try await runtime.object(native).resolve(.objc(.method("updateSettings:", as: ((@escaping SettingsAction) -> Void).self)))
            var updateError: (any Error)?
            let configure: SettingsAction = { settings, _ in
                MainActor.assumeIsolated {
                    do { try unsafe frame.unsafeInvoke(on: settings, CGRect(origin: .zero, size: size)) }
                    catch { updateError = error }
                }
            }
            try unsafe update.unsafeInvoke(configure)
            if let updateError { throw updateError }
        } catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
    }
    #endif

    private static func open(from original: UIWindow, geometry: Geometry) async throws -> PreviewSnapshotWindow {
        do { return try await connect(from: original, geometry: geometry) }
        catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
    }

    private static func connect(from originalWindow: UIWindow, geometry: Geometry) async throws -> PreviewSnapshotWindow {
        let runtime = ABIRuntime.shared
        guard let originalScene = originalWindow.windowScene,
              let originalFBS = try await object(originalScene, "_FBSScene"),
              let originalSettings = try await object(originalFBS, "settings"),
              let specification = try await object(originalFBS, "specification"),
              let displayConfiguration = try await object(originalSettings, "displayConfiguration"),
              let fbsClass = NSClassFromString("FBSScene") else { throw NativePreviewPipelineRequired() }
        #if os(iOS)
        let edgeSymbol = try await runtime.resolve(
            .objc(.symbol(machOName: "_OBJC_CLASS_$_UISApplicationSupportDisplayEdgeInfo", kind: .data)), in: .framework(named: "UIKitServices"))
        guard let edgeClass = NSClassFromString("UISApplicationSupportDisplayEdgeInfo") else { throw NativePreviewPipelineRequired() }
        #endif
        let factory = try await runtime.object(fbsClass as AnyObject).resolve(
            .objc(.method("pseudoSceneWithIdentifier:specification:", as: ((String, AnyObject) -> AnyObject).self)))
        let connect = try await runtime.object(UIApplication.shared).resolve(
            .objc(.method("_connectUISceneFromFBSScene:transitionContext:", as: ((AnyObject, AnyObject?) -> AnyObject?).self)))
        let invalidateUI = try await runtime.resolve(.objc(.method("_invalidate", as: (() -> Void).self)), on: UIWindowScene.self)
        let remove = try await runtime.object(UIApplication.shared).resolve(
            .objc(.method("_removeSessionFromSessionSet:", as: ((UISceneSession) -> Void).self)))
        let identifier = identifierPrefix + UUID().uuidString
        let nativeScene = try unsafe factory.unsafeInvoke(identifier, specification)
        guard let queue = try await object(nativeScene, "callOutQueue") else { throw NativePreviewPipelineRequired() }
        typealias QueueAction = @convention(block) () -> Void
        let enqueue = try await runtime.object(queue).resolve(.objc(.method("performAsync:", as: ((@escaping QueueAction) -> Void).self)))
        let invalidate = try await runtime.object(nativeScene).resolve(.objc(.method("invalidate", as: (() -> Void).self)))
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
            #if os(iOS)
            guard let displayContextClass = NSClassFromString("UISDisplayContext") else { throw NativePreviewPipelineRequired() }
            let edge: AnyObject
            // PreviewShell takes edge information from its display context;
            // the process-wide default can omit the selected iPad's insets.
            if let context = try await object(displayContextClass as AnyObject, "_loadedInitialContext"),
               let selectedEdge = try await object(context, "displayEdgeInfo") {
                edge = selectedEdge
            } else {
                let allocate = try await runtime.object(edgeClass as AnyObject).resolve(.objc(.method("alloc", as: (() -> AnyObject).self)))
                let allocated = try unsafe allocate.unsafeInvoke()
                let initialize = try await runtime.object(allocated).resolve(.objc(.method("init", as: (() -> AnyObject).self)))
                edge = try unsafe initialize.unsafeInvoke()
            }
            let portraitInsets = try await insets(edge, "safeAreaInsetsPortrait")
            let peripheryInsets = try await insets(edge, "peripheryInsets")
            let home = try await object(edge, "homeAffordanceOverlayAllowance") as? NSNumber
            #endif
            let settingsClass: AnyClass = type(of: mutable)
            let frame = try await runtime.resolve(.objc(.method("setFrame:", as: ((CGRect) -> Void).self)), on: settingsClass)
            let interface = try await runtime.resolve(.objc(.method("setInterfaceOrientation:", as: ((Int64) -> Void).self)), on: settingsClass)
            let mode = try await runtime.resolve(.objc(.method("setInterfaceOrientationMode:", as: ((Int64) -> Void).self)), on: settingsClass)
            let device = try await runtime.resolve(.objc(.method("setDeviceOrientation:", as: ((Int64) -> Void).self)), on: settingsClass)
            let display = try await runtime.resolve(.objc(.method("setDisplayConfiguration:", as: ((AnyObject) -> Void).self)), on: settingsClass)
            #if os(iOS)
            let portrait = try await runtime.resolve(.objc(.method("setSafeAreaInsetsPortrait:", as: ((UIEdgeInsets) -> Void).self)), on: settingsClass)
            let periphery = try await runtime.resolve(.objc(.method("setPeripheryInsets:", as: ((UIEdgeInsets) -> Void).self)), on: settingsClass)
            let homeAllowance = try await runtime.resolve(
                .objc(.method("setHomeAffordanceOverlayAllowance:", as: ((Double) -> Void).self)), on: settingsClass)
            let statusHeight = try await runtime.resolve(
                .objc(.method("setDefaultStatusBarHeight:forOrientation:", as: ((Double, Int64) -> Void).self)), on: settingsClass)
            #endif
            let persistence = try await runtime.resolve(.objc(.method("setPersistenceIdentifier:", as: ((String) -> Void).self)), on: settingsClass)
            let foreground = try await runtime.resolve(.objc(.method("setForeground:", as: ((Bool) -> Void).self)), on: settingsClass)
            let referenceFrame: CGRect
            let interfaceOrientation: Int64
            let orientationMode: Int64
            let deviceOrientation: Int64
            #if os(iOS)
            let readHeight = try await runtime.object(originalSettings).resolve(
                .objc(.method("defaultStatusBarHeightForOrientation:", as: ((Int64) -> Double).self)))
            let heights = try [UIInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].map {
                (Int64($0.rawValue), try unsafe readHeight.unsafeInvoke(Int64($0.rawValue)))
            }
            let orientation: UIInterfaceOrientation
            switch geometry { case .display(let value): orientation = value }
            let deviceValue: UIDeviceOrientation
            switch orientation {
            case .portrait: deviceValue = .portrait
            case .portraitUpsideDown: deviceValue = .portraitUpsideDown
            case .landscapeLeft: deviceValue = .landscapeRight
            case .landscapeRight: deviceValue = .landscapeLeft
            default: throw NativePreviewPipelineRequired()
            }
            let screenSize = originalWindow.screen.fixedCoordinateSpace.bounds.size
            // FBS settings bounds rotate this reference frame for the requested
            // orientation; rotating the frame here would rotate the size twice.
            referenceFrame = CGRect(origin: .zero, size: screenSize)
            interfaceOrientation = Int64(orientation.rawValue)
            // PreviewShell.SceneConfigurator passes mode 2 on iOS 27.2.
            orientationMode = 2
            deviceOrientation = Int64(deviceValue.rawValue)
            #else
            switch geometry { case .custom(let size): referenceFrame = CGRect(origin: .zero, size: size) }
            interfaceOrientation = try await integer(originalSettings, "interfaceOrientation")
            orientationMode = try await integer(originalSettings, "interfaceOrientationMode")
            deviceOrientation = try await integer(originalSettings, "deviceOrientation")
            #endif
            typealias SettingsAction = @convention(block) (AnyObject, AnyObject) -> Void
            let update = try await runtime.object(nativeScene).resolve(.objc(.method("updateSettings:", as: ((@escaping SettingsAction) -> Void).self)))
            var transition: AnyObject?
            var updateError: (any Error)?
            let configure: SettingsAction = { settings, context in
                MainActor.assumeIsolated {
                    do {
                        transition = context
                        try unsafe frame.unsafeInvoke(on: settings, referenceFrame)
                        try unsafe interface.unsafeInvoke(on: settings, interfaceOrientation)
                        try unsafe mode.unsafeInvoke(on: settings, orientationMode)
                        try unsafe device.unsafeInvoke(on: settings, deviceOrientation)
                        try unsafe display.unsafeInvoke(on: settings, displayConfiguration)
                        #if os(iOS)
                        try unsafe portrait.unsafeInvoke(on: settings, portraitInsets)
                        try unsafe periphery.unsafeInvoke(on: settings, peripheryInsets)
                        try unsafe homeAllowance.unsafeInvoke(on: settings, home?.doubleValue ?? 0)
                        for (orientation, height) in heights { try unsafe statusHeight.unsafeInvoke(on: settings, height, orientation) }
                        #endif
                        try unsafe persistence.unsafeInvoke(on: settings, identifier)
                        try unsafe foreground.unsafeInvoke(on: settings, true)
                    } catch { updateError = error }
                }
            }
            try unsafe update.unsafeInvoke(configure)
            if let updateError { throw updateError }
            let created = try await runtime.object(nativeScene).resolve(
                .objc(
                    .method(
                        "_callOutQueue_didCreateWithTransitionContext:alternativeCreationCallout:completion:",
                        as: ((AnyObject?, QueueAction?, QueueAction?) -> Void).self)))
            // UIKit content can send scene actions during its first layout.
            // Complete the native creation lifecycle before connecting its scene.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let notify: QueueAction = {
                    do {
                        try unsafe created.unsafeInvoke(transition, nil, nil)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
                do { try unsafe enqueue.unsafeInvoke(notify) }
                catch { continuation.resume(throwing: error) }
            }
            guard let scene = try unsafe connect.unsafeInvoke(nativeScene, transition) as? UIWindowScene else { throw NativePreviewPipelineRequired() }
            connectedScene = scene
            try await synchronizeInitialSettings(of: nativeScene, transitionContext: transition)
            let window = UIWindow(windowScene: scene)
            let session = scene.session
            let owner = PreviewSnapshotWindow(window: window,
                    invalidateScene: { try unsafe invalidateUI.unsafeInvoke(on: scene) },
                    removeSession: { try unsafe remove.unsafeInvoke(session) }, invalidateNativeScene: invalidateNative)
            #if os(iOS)
            return withExtendedLifetime(edgeSymbol) { owner }
            #else
            return owner
            #endif
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

    private static func synchronizeInitialSettings(of nativeScene: AnyObject, transitionContext: AnyObject?) async throws {
        guard let settings = try await object(nativeScene, "settings"),
              let delegate = try await object(nativeScene, "delegate") else { throw NativePreviewPipelineRequired() }
        let runtime = ABIRuntime.shared
        let isUISettings = try await runtime.object(settings).resolve(.objc(.method("isUISubclass", as: (() -> Bool).self)))
        guard try unsafe isUISettings.unsafeInvoke() else { throw NativePreviewPipelineRequired() }
        typealias Completion = @convention(block) @Sendable (AnyObject?) -> Void
        let initialize = try await runtime.object(delegate).resolve(
            .objc(
                .method(
                    "scene:didUpdateWithDiff:transitionContext:completion:", as: ((AnyObject, AnyObject?, AnyObject?, @escaping Completion) -> Void).self)))
        // UIApplication's workspace connection sends this nil-diff notification
        // after _connect. It primes UIKit's previous settings before a resize.
        // The commit-response completion may arrive off the main executor.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: Completion = { _ in continuation.resume() }
            do { try unsafe initialize.unsafeInvoke(nativeScene, nil, transitionContext, completion) }
            catch { continuation.resume(throwing: error) }
        }
    }

    func close() async throws {
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
        let getter = try await ABIRuntime.shared.object(owner).resolve(.objc(.method(selector, as: (() -> AnyObject?).self)))
        return try unsafe getter.unsafeInvoke()
    }

    #if os(iOS)
    private static func insets(_ edge: AnyObject, _ name: String) async throws -> UIEdgeInsets {
        guard let wrapper = try await object(edge, name) else { return .zero }
        var values: [Double] = []
        for field in ["topInset", "leftInset", "bottomInset", "rightInset"] {
            let getter = try await ABIRuntime.shared.object(wrapper).resolve(.objc(.method(field, as: (() -> Double).self)))
            values.append(try unsafe getter.unsafeInvoke())
        }
        return UIEdgeInsets(top: values[0], left: values[1], bottom: values[2], right: values[3])
    }
    #else
    private static func integer(_ owner: AnyObject, _ selector: String) async throws -> Int64 {
        let getter = try await ABIRuntime.shared.object(owner).resolve(.objc(.method(selector, as: (() -> Int64).self)))
        return try unsafe getter.unsafeInvoke()
    }
    #endif
}

@MainActor
private final class PreviewSnapshotScene: UIResponder, UIWindowSceneDelegate {
    #if os(iOS)
    @available(iOS 27.0, *)
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask { .all }
    #endif
}
#endif
