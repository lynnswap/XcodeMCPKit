import AppKit
import ApplicationServices
import Foundation

@safe
@MainActor
final class NativeOrganizerAccessibility {
    struct Row: Equatable, Sendable {
        let name: String
        let displayText: String
    }

    struct Snapshot: Sendable {
        let rows: [Row]
        let filterValues: [String]
        let selectedIssueName: String?
        let busyMessages: [String]
        let errorMessages: [String]
        let listStatusMessages: [String]
        let hasScrollBar: Bool
        let scrollValue: Double?
    }

    let processIdentifier: pid_t
    private let appURL: URL
    private let launchDate: Date?

    init(installation: NativeXcodeInstallation) throws {
        let appURL = installation.contentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").filter {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == appURL
        }
        guard applications.count == 1, let application = applications.first else {
            throw NativeRuntimeError.unavailable(applications.isEmpty
                ? "Open the selected Xcode installation before fetching Organizer crashes: \(appURL.path)"
                : "Several processes run the selected Xcode installation; close the extra processes: \(appURL.path)")
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
        let rows = try nativeRows.map { row -> Row in
            let texts = try find(in: [row]) { try self.role(of: $0) == kAXStaticTextRole as String }
            let named = try texts.compactMap { text -> Row? in
                guard let name = try string(kAXHelpAttribute, from: text), !name.isEmpty else { return nil }
                return Row(name: name, displayText: try string(kAXValueAttribute, from: text) ?? name)
            }
            guard named.count == 1, let value = named.first else {
                throw NativeRuntimeError.unsupportedContract("An Organizer crash row does not expose one signature in AXHelp")
            }
            return value
        }
        var selectedIssueName: String?
        for (element, row) in zip(nativeRows, rows) {
            guard let value = try attribute(kAXSelectedAttribute, from: element) else { continue }
            guard let selected = value as? Bool else {
                throw NativeRuntimeError.unsupportedContract("An Organizer crash row has a nonboolean AXSelected attribute")
            }
            if selected {
                guard selectedIssueName == nil else {
                    throw NativeRuntimeError.unavailable("Several Organizer crash rows are selected")
                }
                selectedIssueName = row.name
            }
        }
        let scrollbar = try verticalScrollBar(in: location.scrollArea)
        let scrollValue: Double?
        if let scrollbar, let value = try attribute(kAXValueAttribute, from: scrollbar) {
            guard let number = value as? NSNumber else {
                throw NativeRuntimeError.unsupportedContract("The Organizer crash scrollbar has a nonnumeric AXValue")
            }
            scrollValue = number.doubleValue
        } else { scrollValue = nil }
        var busy: [String] = []
        var failures: [String] = []
        let statusElements = try find(in: [location.scrollArea], skipTables: true) {
            try self.role(of: $0) == kAXStaticTextRole as String
        }
        let listStatusMessages = try statusElements.flatMap { element -> [String] in
            var texts: [String] = []
            for name in [kAXValueAttribute, kAXTitleAttribute] {
                if let text = try string(name, from: element), !text.isEmpty, !texts.contains(text) { texts.append(text) }
            }
            return texts
        }
        _ = try find(in: [location.window], skipTables: true) { element in
            let role = try self.role(of: element)
            if role == kAXProgressIndicatorRole as String {
                busy.append(try self.string(kAXDescriptionAttribute, from: element)
                    ?? self.string(kAXTitleAttribute, from: element) ?? "AXProgressIndicator")
            } else if role == kAXStaticTextRole as String,
                      let text = try self.string(kAXValueAttribute, from: element) {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["loading", "downloading", "読み込み", "ダウンロード中"].contains(where: normalized.hasPrefix) {
                    busy.append(text)
                }
                if ["error", "failed", "unable", "cannot", "could not", "an error", "エラー", "失敗"].contains(where: normalized.hasPrefix) {
                    failures.append(text)
                }
            }
            return false
        }
        return Snapshot(rows: rows, filterValues: try filterValues(in: location.window), selectedIssueName: selectedIssueName,
                        busyMessages: Array(Set(busy)).sorted(), errorMessages: Array(Set(failures)).sorted(),
                        listStatusMessages: listStatusMessages, hasScrollBar: scrollbar != nil, scrollValue: scrollValue)
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

    func scrollToBottom() throws {
        let location = try locateList()
        guard let scrollbar = try verticalScrollBar(in: location.scrollArea) else { return }
        let result = AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, NSNumber(value: 1.0))
        guard result == .success else { throw failure("Set the Organizer crash scrollbar AXValue", result) }
    }

    func reload() throws {
        guard let menuBar = try element(kAXMenuBarAttribute, from: applicationElement()) else {
            throw NativeRuntimeError.unavailable("The selected Xcode process does not expose its menu bar")
        }
        // AppKit exposes stale references for descendants of closed menus.
        // Open View before resolving its live Reload Organizer command.
        let menuItems = try children(of: menuBar)
        guard let viewMenu = try menuItems.first(where: { try string(kAXTitleAttribute, from: $0) == "View" }) else {
            throw NativeRuntimeError.unavailable("Xcode does not expose its View menu")
        }
        let show = AXUIElementPerformAction(viewMenu, kAXPressAction as CFString)
        guard show == .success else { throw failure("Open Xcode's View menu", show) }
        let items = try find(in: [viewMenu]) { element in
            try self.string(kAXIdentifierAttribute, from: element) == "productsWindow_reload:"
        }
        guard items.count == 1, let item = items.first else {
            throw NativeRuntimeError.unavailable("Xcode does not expose the Reload Organizer menu item (productsWindow_reload:)")
        }
        guard let enabled = try attribute(kAXEnabledAttribute, from: item) as? Bool else {
            throw NativeRuntimeError.unsupportedContract("Reload Organizer has no boolean AXEnabled attribute")
        }
        guard enabled else { throw NativeRuntimeError.unavailable("Reload Organizer is disabled in the selected Xcode process") }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else { throw failure("Press Reload Organizer", result) }
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
        guard lists.count == 1, let (window, group) = lists.first else {
            throw NativeRuntimeError.unavailable(lists.isEmpty
                ? "Open Organizer's Crashes view in the selected Xcode installation"
                : "Several Organizer crash lists are open in the selected Xcode process")
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

    private func filterValues(in window: AXUIElement) throws -> [String] {
        let scrollAreas = try find(in: [window], skipTables: true) {
            try self.role(of: $0) == kAXScrollAreaRole as String
        }
        var candidates: [[String]] = []
        for scrollArea in scrollAreas {
            let collections = try find(in: try children(of: scrollArea), skipTables: true) { element in
                let role = try self.role(of: element)
                if role == "AXCollection" || role == kAXListRole as String { return true }
                return try self.string(kAXRoleDescriptionAttribute, from: element)?.lowercased() == "collection"
            }
            for collection in collections {
                let popups = try find(in: [collection], skipTables: true) {
                    try self.role(of: $0) == kAXPopUpButtonRole as String
                }
                guard !popups.isEmpty else { continue }
                candidates.append(try popups.map { popup in
                    guard let value = try string(kAXValueAttribute, from: popup) ?? string(kAXTitleAttribute, from: popup) else {
                        throw NativeRuntimeError.unsupportedContract("An Organizer crash filter has no value or title")
                    }
                    return value
                })
            }
        }
        guard candidates.count == 1, let values = candidates.first else {
            throw NativeRuntimeError.unsupportedContract("The Organizer crash window does not expose one filter collection")
        }
        return values
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
                if skipTables, try role(of: element) == kAXTableRole as String { continue }
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
        default: throw failure("Read Organizer \(name) from \(element)", result)
        }
    }

    private func failure(_ operation: String, _ error: ApplicationServices.AXError) -> NSError {
        NSError(domain: "XcodeMCPKit.OrganizerAccessibility", code: Int(error.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with AX error \(error.rawValue)"])
    }
}
