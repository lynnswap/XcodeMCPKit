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
            throw NativeRuntimeError.unavailable("The owned Organizer application is not running from the selected Xcode installation: \(appURL.path)")
        }
        guard AXIsProcessTrusted() else {
            throw NativeRuntimeError.unavailable("Accessibility access is required for the native host to operate Xcode Organizer")
        }
        processIdentifier = application.processIdentifier
        self.application = application
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
            try scrollToBottom(scrollbar)
            return
        }
        let windowFrame = try frame(of: location.window)
        let listFrame = try frame(of: location.scrollArea)
        let number = try windowNumber(frame: windowFrame)
        // AXSize enforces the interactive minimum size. Xcode's standard
        // scripting bounds use setFrame:display:, which can make a hidden
        // viewport small enough to scroll even a single issue.
        let height = Int(ceil(windowFrame.height - listFrame.height)) + 1
        try await Self.withTemporaryWindowHeight(height, readBounds: {
            _ = try self.applicationElement()
            return try await Self.readWindowBounds(processIdentifier: self.processIdentifier, windowNumber: number)
        }, writeBounds: { bounds in
            _ = try self.applicationElement()
            try await Self.writeWindowBounds(bounds, processIdentifier: self.processIdentifier, windowNumber: number)
        }, operation: {
            let resized = try self.locateList()
            guard let scrollbar = try self.verticalScrollBar(in: resized.scrollArea) else { throw ViewUpdating() }
            try self.scrollToBottom(scrollbar)
        })
    }

    private func scrollToBottom(_ scrollbar: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, NSNumber(value: 1.0))
        guard result == .success else { throw failure("Set the Organizer crash scrollbar AXValue", result) }
    }

    struct WindowBounds: Equatable, Sendable {
        let top: Int16
        let left: Int16
        let bottom: Int16
        let right: Int16

        init(top: Int16, left: Int16, bottom: Int16, right: Int16) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        nonisolated init(data: Data) throws {
            guard data.count == 8 else {
                throw NativeRuntimeError.unsupportedContract("Organizer scripting bounds are not an 8-byte QuickDraw rectangle")
            }
            let values = unsafe data.withUnsafeBytes { bytes in
                (0..<4).map { unsafe bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
            }
            top = values[0]
            left = values[1]
            bottom = values[2]
            right = values[3]
        }

        nonisolated var data: Data {
            [top, left, bottom, right].withUnsafeBytes { unsafe Data($0) }
        }

        func withHeight(_ height: Int) throws -> WindowBounds {
            guard let bottom = Int16(exactly: Int(top) + height) else {
                throw NativeRuntimeError.unsupportedContract("The temporary Organizer height cannot be represented by its scripting rectangle")
            }
            return WindowBounds(top: top, left: left, bottom: bottom, right: right)
        }
    }

    static func withTemporaryWindowHeight(_ height: Int,
        readBounds: @MainActor () async throws -> WindowBounds,
        writeBounds: @escaping @MainActor (WindowBounds) async throws -> Void,
        operation: @MainActor () async throws -> Void) async throws {
        let original = try await readBounds()
        let resized = try original.withHeight(height)
        let outcome: Result<Void, any Error>
        do {
            try Task.checkCancellation()
            try await writeBounds(resized)
            try await operation()
            outcome = .success(())
        } catch { outcome = .failure(error) }
        // A cancelled acquisition still restores the owned window before its
        // application is reused or shut down.
        let restore = Task { @MainActor in try await writeBounds(original) }
        do { try await restore.value }
        catch {
            if case .failure(let original) = outcome {
                throw NSError(domain: "XcodeMCPKit.OrganizerAccessibility", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Organizer pagination and window restoration failed",
                    NSMultipleUnderlyingErrorsKey: [original as NSError, error as NSError],
                ])
            }
            throw error
        }
        try outcome.get()
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
            throw NativeRuntimeError.unsupportedContract("The owned Organizer window has no unique window number for its frame")
        }
        return number
    }

    private nonisolated static func readWindowBounds(processIdentifier: pid_t, windowNumber: Int) async throws -> WindowBounds {
        try await Task.detached {
            let value = try sendWindowBounds(processIdentifier: processIdentifier, windowNumber: windowNumber)
            guard value.descriptorType == DescType(typeQDRectangle) else {
                throw NativeRuntimeError.unsupportedContract("Organizer scripting bounds are not a QuickDraw rectangle")
            }
            return try WindowBounds(data: value.data)
        }.value
    }

    private nonisolated static func writeWindowBounds(_ bounds: WindowBounds, processIdentifier: pid_t,
                                                      windowNumber: Int) async throws {
        try await Task.detached {
            _ = try sendWindowBounds(processIdentifier: processIdentifier, windowNumber: windowNumber, bounds: bounds)
        }.value
    }

    private nonisolated static func sendWindowBounds(processIdentifier: pid_t, windowNumber: Int,
                                                     bounds: WindowBounds? = nil) throws -> NSAppleEventDescriptor {
        var identifier = Int64(windowNumber)
        let identifierData = withUnsafeBytes(of: &identifier) { unsafe Data($0) }
        guard let identifier = NSAppleEventDescriptor(descriptorType: DescType(typeSInt64), data: identifierData) else {
            throw NativeRuntimeError.unavailable("Could not encode the owned Organizer window number")
        }
        let window = NSAppleEventDescriptor.record()
        window.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cWindow)), forKeyword: AEKeyword(keyAEDesiredClass))
        window.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
        window.setDescriptor(identifier, forKeyword: AEKeyword(keyAEKeyData))
        window.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        guard let object = window.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw NativeRuntimeError.unavailable("Could not encode the owned Organizer window specifier")
        }
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(pBounds)), forKeyword: AEKeyword(keyAEKeyData))
        property.setDescriptor(object, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = property.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw NativeRuntimeError.unavailable("Could not encode the owned Organizer bounds specifier")
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(bounds == nil ? kAEGetData : kAESetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        if let bounds {
            guard let data = NSAppleEventDescriptor(descriptorType: DescType(typeQDRectangle), data: bounds.data) else {
                throw NativeRuntimeError.unavailable("Could not encode the temporary Organizer bounds")
            }
            event.setParam(data, forKeyword: AEKeyword(keyAEData))
        }
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .dontRecord,
            .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
        let reply = try event.sendEvent(options: options, timeout: 5)
        let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        guard code == 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                    ?? "Organizer scripting bounds request failed",
            ])
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
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
            throw NativeRuntimeError.unavailable("The owned Organizer application is no longer running with its original process identity; resolve Organizer again")
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
