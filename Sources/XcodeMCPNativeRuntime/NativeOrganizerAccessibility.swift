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
    private let application: NSRunningApplication

    init(installation: NativeXcodeInstallation, application: NSRunningApplication) throws {
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        guard !application.isTerminated, application.processIdentifier > 0,
              application.bundleURL?.resolvingSymlinksInPath() == appURL else {
            throw NativeRuntimeError.unavailable("The selected Organizer application is not running from the selected Xcode installation: \(appURL.path)")
        }
        guard AXIsProcessTrusted() else {
            throw NativeRuntimeError.unavailable("Accessibility access is required for the native host to operate Xcode Organizer")
        }
        processIdentifier = application.processIdentifier
        self.application = application
    }

    func reload() throws {
        let app = try applicationElement()
        guard let menuBar = try element(kAXMenuBarAttribute, from: app) else {
            throw NativeRuntimeError.unsupportedContract("Xcode does not expose its menu bar for Organizer reload")
        }
        let matches = try find(in: [menuBar]) {
            try self.role(of: $0) == kAXMenuItemRole as String
                && self.string(kAXIdentifierAttribute, from: $0) == "productsWindow_reload:"
        }
        guard matches.count == 1, let item = matches.first else {
            throw NativeRuntimeError.unsupportedContract("Xcode does not expose one Reload Organizer menu item")
        }
        guard let enabled = try attribute(kAXEnabledAttribute, from: item) as? NSNumber, enabled.boolValue else {
            throw NativeRuntimeError.unavailable("Xcode's Reload Organizer menu item is disabled")
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else { throw failure("Reload Xcode Organizer", result) }
    }

    func snapshot() throws -> Snapshot {
        let location = try locateList()
        let nativeRows: [AXUIElement]
        // Only loading/status rows need inspection. Reading every accumulated
        // issue through AX makes each successive page more expensive.
        if let rows = try elements(kAXVisibleRowsAttribute, from: location.table) {
            nativeRows = rows
        } else if let rows = try elements(kAXRowsAttribute, from: location.table) {
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
        let windowFrame = try frame(of: location.window)
        let listFrame = try frame(of: location.scrollArea)
        let number = try windowNumber(frame: windowFrame)
        let point = CGPoint(x: listFrame.midX - windowFrame.minX, y: listFrame.midY - windowFrame.minY)
        let height = CGDisplayBounds(CGMainDisplayID()).height
        // A short list has no scrollbar. Its elastic scroll still publishes a
        // downward bounds change, which Organizer uses to request the next page.
        // Target the window directly so the pointer and frontmost app stay put.
        let end = try Self.scrollEvent(windowNumber: number, at: point, displayHeight: height, phase: .ended, delta: 0)
        let outcome: Result<Void, any Error>
        do {
            for phase in [CGScrollPhase.began, .changed, .changed] {
                try Task.checkCancellation()
                _ = try applicationElement()
                let event = try Self.scrollEvent(windowNumber: number, at: point, displayHeight: height,
                                                 phase: phase, delta: -120)
                event.postToPid(processIdentifier)
                try await Task.sleep(for: .milliseconds(100))
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        do {
            _ = try applicationElement()
            end.postToPid(processIdentifier)
        } catch {
            if case .failure(let original) = outcome {
                throw NSError(domain: "XcodeMCPKit.OrganizerAccessibility", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Organizer pagination and scroll completion failed",
                    NSMultipleUnderlyingErrorsKey: [original as NSError, error as NSError],
                ])
            }
            throw error
        }
        try outcome.get()
    }

    static func scrollEvent(windowNumber: Int, at point: CGPoint, displayHeight: CGFloat,
                            phase: CGScrollPhase, delta: Int32) throws -> CGEvent {
        // AppKit retains the recipient's window number in the event. With a
        // remote window, its CG location must be window-local and top-left based.
        let seed = CGPoint(x: point.x, y: displayHeight - point.y)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: seed, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)?.cgEvent,
              let payload = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: delta, wheel2: 0, wheel3: 0) else {
            throw NativeRuntimeError.unavailable("Could not create the Organizer scroll event")
        }
        event.type = .scrollWheel
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3] {
            event.setIntegerValueField(field, value: payload.getIntegerValueField(field))
        }
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                      .scrollWheelEventFixedPtDeltaAxis3] {
            event.setDoubleValueField(field, value: payload.getDoubleValueField(field))
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.flags = []
        return event
    }

    private func windowNumber(frame: CGRect) throws -> Int {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = windows.compactMap { window -> Int? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: bounds), rectangle == frame else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.intValue
        }
        guard matches.count == 1, let number = matches.first else {
            throw NativeRuntimeError.unsupportedContract("The selected Organizer window has no unique window number for its frame")
        }
        return number
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

    private func applicationElement() throws -> AXUIElement {
        guard let current = NSRunningApplication(processIdentifier: processIdentifier),
              current.isEqual(application), !current.isTerminated else {
            throw NativeRuntimeError.unavailable("The selected Organizer application is no longer running with its original process identity; resolve Organizer again")
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
