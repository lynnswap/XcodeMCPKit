import AppKit
import ApplicationServices
import Foundation

@safe
@MainActor
final class NativeOrganizerAccessibility {
    struct ViewUpdating: LocalizedError {
        var errorDescription: String? { "Organizer is updating its crash view" }
    }
    struct Snapshot: Sendable {
        let busyMessages: [String]
        let listStatusMessages: [String]
    }

    let processIdentifier: pid_t
    private let appURL: URL
    private let launchDate: Date?

    init(installation: NativeXcodeInstallation, application: NSRunningApplication) throws {
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        guard !application.isTerminated, application.processIdentifier > 0,
              application.bundleURL?.resolvingSymlinksInPath() == appURL else {
            throw NativeRuntimeError.unavailable("The owned Organizer application is not running from the selected Xcode installation: \(appURL.path)")
        }
        guard AXIsProcessTrusted() else {
            throw NativeRuntimeError.unavailable("Accessibility access is required for the native host to operate Xcode Organizer")
        }
        processIdentifier = application.processIdentifier
        self.appURL = appURL
        launchDate = application.launchDate
    }

    func snapshot() throws -> Snapshot {
        let location = try locateList()
        let nativeRows: [AXUIElement]
        if let rows = try elements(kAXRowsAttribute, from: location.table) {
            nativeRows = rows
        } else {
            nativeRows = try children(of: location.table).filter { try role(of: $0) == kAXRowRole as String }
        }
        var rowStatus: [String] = []
        for row in nativeRows {
            let texts = try find(in: [row]) { try self.role(of: $0) == kAXStaticTextRole as String }
            let names = try texts.compactMap { text -> String? in
                guard let name = try string(kAXHelpAttribute, from: text), !name.isEmpty else { return nil }
                return name
            }
            if !names.isEmpty { continue }
            // Infinite paging also exposes loading and status rows. They have
            // no crash signature and belong to the status, not the issue list.
            rowStatus += try texts.compactMap { try string(kAXValueAttribute, from: $0) ?? string(kAXTitleAttribute, from: $0) }
        }
        var busy: [String] = []
        let listFrame = try frame(of: location.scrollArea)
        // The initial-page placeholder is a sibling of the scroll view.
        // Restrict status text to that pane; signatures and exception reasons
        // elsewhere in the window are crash data, even if they say "Error".
        let statusElements = try find(in: [location.group], skipTables: true) {
            guard try self.role(of: $0) == kAXStaticTextRole as String else { return false }
            return try self.frame(of: $0).intersects(listFrame)
        }
        let listStatusMessages = rowStatus + (try statusElements.flatMap { element -> [String] in
            var texts: [String] = []
            for name in [kAXValueAttribute, kAXTitleAttribute] {
                if let text = try string(name, from: element), !text.isEmpty, !texts.contains(text) { texts.append(text) }
            }
            return texts
        })
        _ = try find(in: [location.window], skipTables: true) { element in
            let role = try self.role(of: element)
            if role == kAXProgressIndicatorRole as String {
                busy.append(try self.string(kAXDescriptionAttribute, from: element)
                    ?? self.string(kAXTitleAttribute, from: element) ?? "AXProgressIndicator")
            }
            return false
        }
        for text in listStatusMessages {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["loading", "downloading", "読み込み", "ダウンロード中"].contains(where: value.hasPrefix) { busy.append(text) }
        }
        return Snapshot(busyMessages: Array(Set(busy)).sorted(),
                        listStatusMessages: listStatusMessages)
    }

    func prepareList() throws {
        let location = try locateList()
        let fields = try find(in: [location.group], skipTables: true) {
            try self.string(kAXIdentifierAttribute, from: $0) == "filter"
        }
        guard fields.count == 1, let field = fields.first else {
            throw NativeRuntimeError.unsupportedContract("The Organizer crash list does not expose one name search field (filter)")
        }
        guard try role(of: field) == kAXTextFieldRole as String,
              let search = try string(kAXValueAttribute, from: field) else {
            throw NativeRuntimeError.unsupportedContract("The Organizer crash name search field has no string AXValue")
        }
        let checkboxes = try find(in: [field]) { try self.role(of: $0) == kAXCheckBoxRole as String }
        guard checkboxes.count == 1, let checkbox = checkboxes.first else {
            throw NativeRuntimeError.unsupportedContract("The Organizer crash name search field does not expose one unresolved-only checkbox")
        }
        guard let value = try attribute(kAXValueAttribute, from: checkbox) as? NSNumber,
              value.doubleValue == 0 || value.doubleValue == 1 else {
            throw NativeRuntimeError.unsupportedContract("The Organizer unresolved-only checkbox has no boolean AXValue")
        }
        if !search.isEmpty {
            let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
            guard result == .success else { throw failure("Clear the Organizer crash name search", result) }
        }
        if value.boolValue {
            let result = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
            guard result == .success else { throw failure("Disable the Organizer unresolved-only filter", result) }
        }
    }

    func scrollToBottom() async throws {
        let location = try locateList()
        if let scrollbar = try verticalScrollBar(in: location.scrollArea) {
            let result = AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, NSNumber(value: 1.0))
            guard result == .success else { throw failure("Set the Organizer crash scrollbar AXValue", result) }
            return
        }
        // A short page can fit without a scrollbar. A continuous gesture still
        // overscrolls its clip view and asks Organizer to load the next page.
        guard CGPreflightPostEventAccess() else {
            throw NativeRuntimeError.unavailable("Accessibility permission is required to scroll the owned Organizer crash list")
        }
        let scrollFrame = try frame(of: location.scrollArea)
        let center = CGPoint(x: scrollFrame.midX.rounded(), y: scrollFrame.midY.rounded())
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            throw NativeRuntimeError.unavailable("The owned Organizer application ended before scrolling")
        }
        _ = application.activate(options: [.activateAllWindows])
        let raised = AXUIElementPerformAction(location.window, kAXRaiseAction as CFString)
        guard raised == .success else { throw failure("Raise the owned Organizer crash list", raised) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            try Task.checkCancellation()
            _ = try applicationElement()
            if application.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
               try ownsScreenPoint(center) { break }
            guard clock.now < deadline else {
                throw NativeRuntimeError.unavailable("The owned Organizer crash list did not become the frontmost pointer target")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let originalCursor = CGEvent(source: nil)?.location else {
            throw NativeRuntimeError.unavailable("Could not read the pointer position before scrolling Organizer")
        }
        let moved = CGWarpMouseCursorPosition(center)
        guard moved == .success else { throw pointerFailure("Move the pointer over Organizer", moved) }
        let placedCursor = center
        var gestureActive = false
        let outcome: Result<Void, any Error>
        do {
            try verifyPointer(placedCursor)
            guard let hover = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: placedCursor, mouseButton: .left) else {
                throw NativeRuntimeError.unavailable("Could not create the Organizer pointer event")
            }
            hover.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(100))
            let phases: [(CGScrollPhase, Int32)] = [(.began, -120)]
                + Array(repeating: (.changed, -120), count: 10) + [(.ended, 0)]
            for (phase, delta) in phases {
                try Task.checkCancellation()
                try verifyPointer(placedCursor)
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
                    throw NativeRuntimeError.unavailable("Could not create the Organizer scroll event")
                }
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                event.location = placedCursor
                event.post(tap: .cghidEventTap)
                gestureActive = phase != .ended
                try await Task.sleep(for: .milliseconds(100))
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        var cleanup: [any Error] = []
        if gestureActive, (try? verifyPointer(placedCursor)) != nil {
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) {
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.cancelled.rawValue))
                event.location = placedCursor
                event.post(tap: .cghidEventTap)
            } else {
                cleanup.append(NativeRuntimeError.unavailable("Could not create the Organizer gesture cancellation event"))
            }
        }
        let restoration: (any Error)?
        if let current = CGEvent(source: nil)?.location {
            // Preserve a person's new pointer position if they intervened.
            if current == placedCursor {
                let restored = CGWarpMouseCursorPosition(originalCursor)
                restoration = restored == .success ? nil : pointerFailure("Restore the pointer after scrolling Organizer", restored)
            } else { restoration = nil }
        } else {
            restoration = NativeRuntimeError.unavailable("Could not read the pointer position to restore it after scrolling Organizer")
        }
        if let restoration { cleanup.append(restoration) }
        if !cleanup.isEmpty {
            if case .failure(let original) = outcome {
                cleanup.insert(original, at: 0)
            }
            let combined = NSError(domain: "XcodeMCPKit.OrganizerPointer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Organizer scroll gesture cleanup failed",
                NSMultipleUnderlyingErrorsKey: cleanup.map { $0 as NSError },
            ])
            if Task.isCancelled { NativeExecutionOperations.scope?.recordFailure(combined) }
            throw combined
        }
        try outcome.get()
    }

    private func frame(of element: AXUIElement) throws -> CGRect {
        guard let positionValue = try attribute(kAXPositionAttribute, from: element),
              let sizeValue = try attribute(kAXSizeAttribute, from: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw NativeRuntimeError.unsupportedContract("The Organizer crash scroll area has no position or size")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        let hasPosition = unsafe AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position)
        let hasSize = unsafe AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        guard hasPosition, hasSize else {
            throw NativeRuntimeError.unsupportedContract("The Organizer crash scroll area has an invalid position or size")
        }
        return CGRect(origin: position, size: size)
    }

    private func ownsScreenPoint(_ point: CGPoint) throws -> Bool {
        var target: AXUIElement?
        let hit = unsafe AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &target)
        guard hit == .success, let target else { throw failure("Find the pointer target for Organizer scrolling", hit) }
        var pid: pid_t = 0
        let result = unsafe AXUIElementGetPid(target, &pid)
        guard result == .success else { throw failure("Read the Organizer pointer target process", result) }
        return pid == processIdentifier
    }

    private func verifyPointer(_ expected: CGPoint) throws {
        _ = try applicationElement()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            throw NativeRuntimeError.unavailable("Organizer lost focus while scrolling; collection stopped")
        }
        guard CGEvent(source: nil)?.location == expected else {
            throw NativeRuntimeError.unavailable("The pointer moved while scrolling Organizer; collection stopped")
        }
        guard try ownsScreenPoint(expected) else {
            throw NativeRuntimeError.unavailable("Another application covered the Organizer scroll target; collection stopped")
        }
    }

    private func pointerFailure(_ operation: String, _ error: CGError) -> NSError {
        NSError(domain: "XcodeMCPKit.OrganizerPointer", code: Int(error.rawValue), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed with Core Graphics error \(error.rawValue) (PID \(processIdentifier))",
        ])
    }

    private func applicationElement() throws -> AXUIElement {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isTerminated,
              application.bundleURL?.resolvingSymlinksInPath() == appURL, application.launchDate == launchDate else {
            throw NativeRuntimeError.unavailable("The selected Xcode process ended; resolve Organizer again")
        }
        return AXUIElementCreateApplication(processIdentifier)
    }

    private func locateList() throws -> (window: AXUIElement, group: AXUIElement, table: AXUIElement, scrollArea: AXUIElement) {
        let app = try applicationElement()
        let windows = try elements(kAXWindowsAttribute, from: app, allowUnsupported: false) ?? []
        var lists: [(AXUIElement, AXUIElement)] = []
        for window in windows {
            let groups = try find(in: [window], skipTables: true) { element in
                guard try self.role(of: element) == kAXSplitGroupRole as String else { return false }
                return try self.string(kAXIdentifierAttribute, from: element) == "Analytics Points Source List"
                    || self.string(kAXDescriptionAttribute, from: element) == "Analytics Points Source List"
            }
            for group in groups { lists.append((window, group)) }
        }
        guard !lists.isEmpty else { throw ViewUpdating() }
        guard lists.count == 1, let (window, group) = lists.first else {
            throw NativeRuntimeError.unavailable("Several Organizer crash lists are open in the selected Xcode process")
        }
        let tables = try find(in: [group]) { try self.role(of: $0) == kAXTableRole as String }
        guard tables.count == 1, let table = tables.first else {
            throw NativeRuntimeError.unsupportedContract("The Organizer Analytics Points Source List does not expose one crash table")
        }
        var ancestor = try element(kAXParentAttribute, from: table)
        while let current = ancestor, !CFEqual(current, group) {
            if try role(of: current) == kAXScrollAreaRole as String { return (window, group, table, current) }
            ancestor = try element(kAXParentAttribute, from: current)
        }
        throw NativeRuntimeError.unsupportedContract("The Organizer crash table has no enclosing scroll area")
    }

    private func verticalScrollBar(in scrollArea: AXUIElement) throws -> AXUIElement? {
        if let scrollbar = try element(kAXVerticalScrollBarAttribute, from: scrollArea) { return scrollbar }
        let bars = try children(of: scrollArea).filter { try role(of: $0) == kAXScrollBarRole as String }
        let vertical = try bars.filter {
            try string(kAXOrientationAttribute, from: $0) == kAXVerticalOrientationValue as String
        }
        if vertical.count == 1 { return vertical.first }
        if bars.count == 1 { return bars.first }
        if bars.isEmpty { return nil }
        throw NativeRuntimeError.unsupportedContract("The Organizer crash list has no identifiable vertical scrollbar")
    }

    private func find(in roots: [AXUIElement], skipTables: Bool = false,
                      matching: (AXUIElement) throws -> Bool) throws -> [AXUIElement] {
        var pending = Array(roots.reversed())
        var visited: [AXUIElement] = []
        var matches: [AXUIElement] = []
        while let element = pending.popLast() {
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            do {
                if try matching(element) { matches.append(element); continue }
                if skipTables {
                    let role = try role(of: element)
                    if role == kAXTableRole as String || role == kAXOutlineRole as String { continue }
                }
                pending.append(contentsOf: try children(of: element).reversed())
            } catch let error as NSError where error.domain == "XcodeMCPKit.OrganizerAccessibility"
                && error.code == ApplicationServices.AXError.invalidUIElement.rawValue {
                // Unrelated, lazy views can disappear while enumerating a window.
                continue
            }
        }
        return matches
    }

    private func role(of element: AXUIElement) throws -> String? { try string(kAXRoleAttribute, from: element) }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        try elements(kAXChildrenAttribute, from: element) ?? []
    }

    private func string(_ name: String, from element: AXUIElement) throws -> String? {
        guard let value = try attribute(name, from: element) else { return nil }
        guard let string = value as? String else {
            throw NativeRuntimeError.unsupportedContract("Organizer \(name) is not a string")
        }
        return string
    }

    private func element(_ name: String, from element: AXUIElement) throws -> AXUIElement? {
        guard let value = try attribute(name, from: element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw NativeRuntimeError.unsupportedContract("Organizer \(name) is not an accessibility element")
        }
        return unsafe unsafeDowncast(value, to: AXUIElement.self)
    }

    private func elements(_ name: String, from element: AXUIElement, allowUnsupported: Bool = true) throws -> [AXUIElement]? {
        guard let value = try attribute(name, from: element, allowUnsupported: allowUnsupported) else { return nil }
        guard let elements = value as? [AXUIElement] else {
            throw NativeRuntimeError.unsupportedContract("Organizer \(name) is not an accessibility element array")
        }
        return elements
    }

    private func attribute(_ name: String, from element: AXUIElement, allowUnsupported: Bool = true) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = unsafe AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch result {
        case .success, .noValue: return value
        case .attributeUnsupported where allowUnsupported: return nil
        default:
            throw NSError(domain: "XcodeMCPKit.OrganizerAccessibility", code: Int(result.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Read Organizer \(name) failed with AX error \(result.rawValue)",
                           "AXAttribute": name])
        }
    }

    private func failure(_ operation: String, _ error: ApplicationServices.AXError) -> NSError {
        NSError(domain: "XcodeMCPKit.OrganizerAccessibility", code: Int(error.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with AX error \(error.rawValue)"])
    }
}
