import Foundation

struct XcodeListWindowsEntry: Sendable, Equatable {
    let tabIdentifier: String
    let workspacePath: String

    init(tabIdentifier: String, workspacePath: String) {
        self.tabIdentifier = tabIdentifier
        self.workspacePath = workspacePath
    }
}

enum XcodeListWindowsMessageParser {
    static func parse(_ message: String) -> [XcodeListWindowsEntry] {
        message
            .split(separator: "\n")
            .compactMap { line -> XcodeListWindowsEntry? in
                var rawLine = String(line)
                if rawLine.hasSuffix("\r") {
                    rawLine.removeLast()
                }
                rawLine.removeLeadingSpacesAndTabs()
                let prefix = "* tabIdentifier: "
                guard rawLine.hasPrefix(prefix) else { return nil }
                let delimiter = ", workspacePath: "
                let searchStart = rawLine.index(rawLine.startIndex, offsetBy: prefix.count)
                guard let delimiterRange = rawLine.range(
                    of: delimiter,
                    options: [],
                    range: searchStart..<rawLine.endIndex
                ) else {
                    return nil
                }
                let tabIdentifier = String(rawLine[searchStart..<delimiterRange.lowerBound])
                let workspacePath = String(rawLine[delimiterRange.upperBound...])
                guard tabIdentifier.isEmpty == false, workspacePath.isEmpty == false else {
                    return nil
                }
                return XcodeListWindowsEntry(
                    tabIdentifier: tabIdentifier,
                    workspacePath: workspacePath
                )
            }
    }
}

private extension String {
    mutating func removeLeadingSpacesAndTabs() {
        let trimmedStart = drop { $0 == " " || $0 == "\t" }
        if trimmedStart.startIndex != startIndex {
            self = String(trimmedStart)
        }
    }
}
