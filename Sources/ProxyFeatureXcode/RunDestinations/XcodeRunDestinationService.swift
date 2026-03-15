import Foundation
import ProxyCore
import ProxyRuntime

package struct XcodeRunDestinationDescriptor: Sendable, Equatable {
    package let name: String
    package let normalizedPlatform: String
    package let rawPlatform: String
    package let deviceName: String
    package let deviceModel: String?
    package let deviceFamily: String
    package let osVersion: String?
    package let architecture: String
    package let generic: Bool
    package let rosetta: Bool

    package var foundationObject: [String: Any] {
        [
            "name": name,
            "normalizedPlatform": normalizedPlatform,
            "rawPlatform": rawPlatform,
            "deviceName": deviceName,
            "deviceModel": deviceModel ?? NSNull(),
            "deviceFamily": deviceFamily,
            "osVersion": osVersion ?? NSNull(),
            "architecture": architecture,
            "generic": generic,
            "rosetta": rosetta,
        ]
    }
}

package struct XcodeRunDestinationPlatformSummary: Sendable, Equatable {
    package let id: String
    package let label: String
    package let osVersions: [String]
    package let deviceFamilies: [String]

    package var foundationObject: [String: Any] {
        [
            "id": id,
            "label": label,
            "osVersions": osVersions,
            "deviceFamilies": deviceFamilies,
        ]
    }
}

package struct XcodeListRunDestinationsOutput: Sendable, Equatable {
    package let platforms: [XcodeRunDestinationPlatformSummary]
    package let destinations: [XcodeRunDestinationDescriptor]

    package var foundationObject: [String: Any] {
        [
            "platforms": platforms.map(\.foundationObject),
            "destinations": destinations.map(\.foundationObject),
        ]
    }

    package var summaryText: String {
        var lines = ["Available run destinations:"]
        for platform in platforms {
            let versions = platform.osVersions.isEmpty ? "none" : platform.osVersions.joined(separator: ", ")
            let families = platform.deviceFamilies.isEmpty ? "none" : platform.deviceFamilies.joined(separator: ", ")
            lines.append("- \(platform.label) (\(platform.id)): osVersions [\(versions)], deviceFamilies [\(families)]")
        }
        return lines.joined(separator: "\n")
    }
}

package struct XcodeSetActiveRunDestinationOutput: Sendable, Equatable {
    package let selectedDestination: XcodeRunDestinationDescriptor
    package let setterAccepted: Bool
    package let readBackUnavailable: Bool

    package var foundationObject: [String: Any] {
        [
            "selectedDestination": selectedDestination.foundationObject,
            "setterAccepted": setterAccepted,
            "readBackUnavailable": readBackUnavailable,
        ]
    }

    package var summaryText: String {
        """
        Selected run destination "\(selectedDestination.name)" for platform "\(selectedDestination.normalizedPlatform)" and osVersion "\(selectedDestination.osVersion ?? "unknown")". Xcode scripting accepted the setter request, but read-back is unavailable.
        """
    }
}

package struct XcodeRunDestinationToolFailure: Error, Sendable {
    package let message: String
    package let structuredContent: [String: JSONValue]
}

package struct XcodeRunDestinationService: Sendable {
    private struct RawRecord: Sendable, Equatable {
        let name: String
        let rawPlatform: String
        let architecture: String
        let deviceName: String
        let deviceModel: String?
        let osVersion: String?
        let generic: Bool
    }

    private static let recordSeparator = Character(UnicodeScalar(30))
    private static let fieldSeparator = Character(UnicodeScalar(31))
    private static let knownPlatformOrder = [
        "ios-simulator",
        "ios-device",
        "ios-app-on-mac",
        "macos",
        "mac-catalyst",
        "driverkit",
    ]
    private static let knownDeviceFamilyOrder = [
        "iphone",
        "ipad",
        "mac",
        "generic",
        "other",
    ]

    private let processRunner: any ProcessRunning

    package init(processRunner: any ProcessRunning) {
        self.processRunner = processRunner
    }

    package func listRunDestinations(workspacePath: String) async -> Result<XcodeListRunDestinationsOutput, XcodeRunDestinationToolFailure> {
        switch await loadDestinations(workspacePath: workspacePath) {
        case .success(let destinations):
            return .success(
                XcodeListRunDestinationsOutput(
                    platforms: summarizePlatforms(destinations),
                    destinations: sortDestinations(destinations)
                )
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    package func setActiveRunDestination(
        workspacePath: String,
        platform: String,
        osVersion: String?,
        deviceFamily: String?
    ) async -> Result<XcodeSetActiveRunDestinationOutput, XcodeRunDestinationToolFailure> {
        let requestedPlatform = normalizedInput(platform)
        let requestedVersion = normalizedOptionalInput(osVersion)
        let requestedFamily = normalizedOptionalInput(deviceFamily)

        guard requestedPlatform.isEmpty == false else {
            return .failure(
                XcodeRunDestinationToolFailure(
                    message: "platform is required",
                    structuredContent: [:]
                )
            )
        }
        let destinations: [XcodeRunDestinationDescriptor]
        switch await loadDestinations(workspacePath: workspacePath) {
        case .success(let loaded):
            destinations = loaded
        case .failure(let error):
            return .failure(error)
        }

        let platformMatches = destinations.filter { $0.normalizedPlatform == requestedPlatform }
        guard platformMatches.isEmpty == false else {
            return .failure(
                XcodeRunDestinationToolFailure(
                    message: "No run destination matched platform \"\(requestedPlatform)\".",
                    structuredContent: [
                        "requestedPlatform": .string(requestedPlatform),
                        "availablePlatforms": .array(uniquePlatformIDs(from: destinations).map(JSONValue.string)),
                    ]
                )
            )
        }

        let versionMatches: [XcodeRunDestinationDescriptor]
        if let requestedVersion {
            versionMatches = platformMatches.filter { $0.osVersion == requestedVersion }
            guard versionMatches.isEmpty == false else {
                return .failure(
                    XcodeRunDestinationToolFailure(
                        message: "No run destination matched platform \"\(requestedPlatform)\" with osVersion \"\(requestedVersion)\".",
                        structuredContent: [
                            "requestedPlatform": .string(requestedPlatform),
                            "requestedOSVersion": .string(requestedVersion),
                            "availableOsVersions": .array(availableOSVersions(from: platformMatches).map(JSONValue.string)),
                        ]
                    )
                )
            }
        } else {
            versionMatches = platformMatches.filter { $0.osVersion == nil }
            guard versionMatches.isEmpty == false else {
                return .failure(
                    XcodeRunDestinationToolFailure(
                        message: "osVersion is required for platform \"\(requestedPlatform)\" because all matching destinations report concrete versions.",
                        structuredContent: [
                            "requestedPlatform": .string(requestedPlatform),
                            "availableOsVersions": .array(availableOSVersions(from: platformMatches).map(JSONValue.string)),
                        ]
                    )
                )
            }
        }

        let familyMatches: [XcodeRunDestinationDescriptor]
        if let requestedFamily, requestedFamily.isEmpty == false {
            familyMatches = versionMatches.filter { $0.deviceFamily == requestedFamily }
            guard familyMatches.isEmpty == false else {
                return .failure(
                    XcodeRunDestinationToolFailure(
                        message: "No run destination matched platform \"\(requestedPlatform)\", osVersion \"\(requestedVersion ?? "unspecified")\", and deviceFamily \"\(requestedFamily)\".",
                        structuredContent: [
                            "requestedPlatform": .string(requestedPlatform),
                            "requestedOSVersion": requestedVersion.map(JSONValue.string) ?? .null,
                            "requestedDeviceFamily": .string(requestedFamily),
                            "availableDeviceFamilies": .array(availableDeviceFamilies(from: versionMatches).map(JSONValue.string)),
                        ]
                    )
                )
            }
        } else {
            familyMatches = versionMatches
        }

        let selected = rankDestinations(
            familyMatches,
            requestedFamily: requestedFamily
        ).first!

        let request = ProcessRequest(
            label: "xcode-set-active-run-destination",
            executablePath: "/usr/bin/osascript",
            arguments: [
                "-",
                workspacePath,
                selected.name,
                selected.rawPlatform,
                selected.architecture,
                selected.deviceName,
                selected.deviceModel ?? "",
                selected.osVersion ?? "",
                selected.generic ? "true" : "false",
            ],
            input: Self.makeSetScript()
        )

        do {
            let output = try await processRunner.run(request)
            guard output.terminationStatus == 0 else {
                return .failure(
                    scriptingFailure(
                        message: "Xcode scripting failed while setting the active run destination.",
                        stdout: output.stdout,
                        stderr: output.stderr
                    )
                )
            }
            return .success(
                XcodeSetActiveRunDestinationOutput(
                    selectedDestination: selected,
                    setterAccepted: true,
                    readBackUnavailable: true
                )
            )
        } catch {
            return .failure(
                scriptingFailure(
                    message: "Failed to launch osascript while setting the active run destination.",
                    stdout: "",
                    stderr: String(describing: error)
                )
            )
        }
    }

    private func loadDestinations(workspacePath: String) async -> Result<[XcodeRunDestinationDescriptor], XcodeRunDestinationToolFailure> {
        let request = ProcessRequest(
            label: "xcode-list-run-destinations",
            executablePath: "/usr/bin/osascript",
            arguments: [
                "-",
                workspacePath,
            ],
            input: Self.makeListScript()
        )

        do {
            let output = try await processRunner.run(request)
            guard output.terminationStatus == 0 else {
                return .failure(
                    scriptingFailure(
                        message: "Xcode scripting failed while listing run destinations.",
                        stdout: output.stdout,
                        stderr: output.stderr
                    )
                )
            }

            let rawRecords = parseRawRecords(output.stdout)
            let destinations = rawRecords.map(normalizeRecord(_:))
            return .success(destinations)
        } catch {
            return .failure(
                scriptingFailure(
                    message: "Failed to launch osascript while listing run destinations.",
                    stdout: "",
                    stderr: String(describing: error)
                )
            )
        }
    }

    private func parseRawRecords(_ text: String) -> [RawRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return []
        }

        return trimmed.split(separator: Self.recordSeparator).compactMap { record in
            let fields = record.split(
                separator: Self.fieldSeparator,
                omittingEmptySubsequences: false
            )
            guard fields.count == 7 else { return nil }

            let name = String(fields[0])
            let rawPlatform = String(fields[1])
            let architecture = String(fields[2])
            let deviceName = String(fields[3])
            let deviceModel = normalizedOptionalValue(String(fields[4]))
            let osVersion = normalizedOptionalValue(String(fields[5]))
            let generic = String(fields[6]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"

            guard name.isEmpty == false, rawPlatform.isEmpty == false else {
                return nil
            }
            return RawRecord(
                name: name,
                rawPlatform: rawPlatform,
                architecture: architecture,
                deviceName: deviceName,
                deviceModel: deviceModel,
                osVersion: osVersion,
                generic: generic
            )
        }
    }

    private func normalizeRecord(_ raw: RawRecord) -> XcodeRunDestinationDescriptor {
        let normalizedPlatform = normalizedPlatform(
            rawPlatform: raw.rawPlatform,
            destinationName: raw.name,
            deviceName: raw.deviceName
        )
        let deviceFamily = deviceFamily(
            rawPlatform: raw.rawPlatform,
            destinationName: raw.name,
            deviceName: raw.deviceName,
            deviceModel: raw.deviceModel,
            generic: raw.generic
        )

        return XcodeRunDestinationDescriptor(
            name: raw.name,
            normalizedPlatform: normalizedPlatform,
            rawPlatform: raw.rawPlatform,
            deviceName: raw.deviceName,
            deviceModel: raw.deviceModel,
            deviceFamily: deviceFamily,
            osVersion: raw.osVersion,
            architecture: raw.architecture,
            generic: raw.generic,
            rosetta: raw.name.localizedCaseInsensitiveContains("Rosetta")
        )
    }

    private func summarizePlatforms(_ destinations: [XcodeRunDestinationDescriptor]) -> [XcodeRunDestinationPlatformSummary] {
        Dictionary(grouping: destinations, by: \.normalizedPlatform)
            .map { platformID, grouped in
                XcodeRunDestinationPlatformSummary(
                    id: platformID,
                    label: platformLabel(for: platformID),
                    osVersions: availableOSVersions(from: grouped),
                    deviceFamilies: availableDeviceFamilies(from: grouped)
                )
            }
            .sorted { lhs, rhs in
                platformSortKey(lhs.id) < platformSortKey(rhs.id)
            }
    }

    private func sortDestinations(_ destinations: [XcodeRunDestinationDescriptor]) -> [XcodeRunDestinationDescriptor] {
        destinations.sorted { lhs, rhs in
            if lhs.normalizedPlatform != rhs.normalizedPlatform {
                return platformSortKey(lhs.normalizedPlatform) < platformSortKey(rhs.normalizedPlatform)
            }
            if lhs.osVersion != rhs.osVersion {
                return shouldSortVersion(lhs.osVersion, before: rhs.osVersion)
            }
            if lhs.deviceFamily != rhs.deviceFamily {
                return deviceFamilySortKey(lhs.deviceFamily) < deviceFamilySortKey(rhs.deviceFamily)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func rankDestinations(
        _ destinations: [XcodeRunDestinationDescriptor],
        requestedFamily: String?
    ) -> [XcodeRunDestinationDescriptor] {
        destinations.sorted { lhs, rhs in
            let lhsKey = selectionSortKey(lhs, requestedFamily: requestedFamily)
            let rhsKey = selectionSortKey(rhs, requestedFamily: requestedFamily)
            return lhsKey.lexicographicallyPrecedes(rhsKey)
        }
    }

    private func selectionSortKey(
        _ destination: XcodeRunDestinationDescriptor,
        requestedFamily: String?
    ) -> [SelectionKeyComponent] {
        [
            .int(destination.generic ? 1 : 0),
            .int(destination.rosetta ? 1 : 0),
            .int(familyPreferenceScore(destination, requestedFamily: requestedFamily)),
            .int(destination.architecture == "arm64" ? 0 : 1),
            .string(destination.name.lowercased()),
        ]
    }

    private func familyPreferenceScore(
        _ destination: XcodeRunDestinationDescriptor,
        requestedFamily: String?
    ) -> Int {
        if let requestedFamily, requestedFamily.isEmpty == false {
            return destination.deviceFamily == requestedFamily ? 0 : 1
        }
        if destination.normalizedPlatform == "ios-simulator" {
            switch destination.deviceFamily {
            case "iphone":
                return 0
            case "ipad":
                return 1
            default:
                return 2
            }
        }
        return 0
    }

    private func availableOSVersions(from destinations: [XcodeRunDestinationDescriptor]) -> [String] {
        Array(Set(destinations.compactMap(\.osVersion)))
            .sorted { shouldSortVersion($0, before: $1) }
    }

    private func availableDeviceFamilies(from destinations: [XcodeRunDestinationDescriptor]) -> [String] {
        Array(Set(destinations.map(\.deviceFamily)))
            .sorted { deviceFamilySortKey($0) < deviceFamilySortKey($1) }
    }

    private func uniquePlatformIDs(from destinations: [XcodeRunDestinationDescriptor]) -> [String] {
        Array(Set(destinations.map(\.normalizedPlatform)))
            .sorted { platformSortKey($0) < platformSortKey($1) }
    }

    private func normalizedPlatform(
        rawPlatform: String,
        destinationName: String,
        deviceName: String
    ) -> String {
        switch rawPlatform {
        case "iphonesimulator":
            return "ios-simulator"
        case "iphoneos":
            return deviceName == "My Mac" ? "ios-app-on-mac" : "ios-device"
        case "macosx":
            return destinationName.localizedCaseInsensitiveContains("Mac Catalyst")
                ? "mac-catalyst"
                : "macos"
        case "driverkit":
            return "driverkit"
        default:
            return rawPlatform
        }
    }

    private func platformLabel(for platformID: String) -> String {
        switch platformID {
        case "ios-simulator":
            return "iOS Simulator"
        case "ios-device":
            return "iOS Device"
        case "ios-app-on-mac":
            return "iOS App on Mac"
        case "macos":
            return "macOS"
        case "mac-catalyst":
            return "Mac Catalyst"
        case "driverkit":
            return "DriverKit"
        default:
            return platformID
        }
    }

    private func deviceFamily(
        rawPlatform: String,
        destinationName: String,
        deviceName: String,
        deviceModel: String?,
        generic: Bool
    ) -> String {
        if generic {
            return "generic"
        }

        let haystacks = [destinationName, deviceName, deviceModel ?? ""]
            .joined(separator: "\n")
            .lowercased()

        if haystacks.contains("iphone") {
            return "iphone"
        }
        if haystacks.contains("ipad") {
            return "ipad"
        }
        if rawPlatform == "macosx" || deviceName == "My Mac" || haystacks.contains("mac") {
            return "mac"
        }
        return "other"
    }

    private func scriptingFailure(
        message: String,
        stdout: String,
        stderr: String
    ) -> XcodeRunDestinationToolFailure {
        XcodeRunDestinationToolFailure(
            message: message,
            structuredContent: [
                "stdout": .string(stdout),
                "stderr": .string(stderr),
            ]
        )
    }

    private func normalizedInput(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedOptionalInput(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.isEmpty == false
        else {
            return nil
        }
        return value.lowercased()
    }

    private func normalizedOptionalValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != "missing value" else {
            return nil
        }
        return trimmed
    }

    private func platformSortKey(_ platformID: String) -> (Int, String) {
        let order = Self.knownPlatformOrder.firstIndex(of: platformID) ?? Int.max
        return (order, platformID)
    }

    private func deviceFamilySortKey(_ deviceFamily: String) -> (Int, String) {
        let order = Self.knownDeviceFamilyOrder.firstIndex(of: deviceFamily) ?? Int.max
        return (order, deviceFamily)
    }

    private func shouldSortVersion(_ lhs: String?, before rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhsValue), .some(rhsValue)):
            let lhsComponents = versionComponents(lhsValue)
            let rhsComponents = versionComponents(rhsValue)
            let count = max(lhsComponents.count, rhsComponents.count)
            for index in 0..<count {
                let lhsComponent = index < lhsComponents.count ? lhsComponents[index] : 0
                let rhsComponent = index < rhsComponents.count ? rhsComponents[index] : 0
                if lhsComponent != rhsComponent {
                    return lhsComponent > rhsComponent
                }
            }
            return lhsValue.localizedStandardCompare(rhsValue) == .orderedAscending
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return false
        }
    }

    private func versionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    private static func makeListScript() -> String {
        """
        on workspaceDocumentForPath(targetPath)
          tell application "Xcode"
            repeat with candidateDocument in workspace documents
              try
                if path of candidateDocument is targetPath then
                  return candidateDocument
                end if
              end try

              try
                repeat with candidateProject in projects of candidateDocument
                  if path of candidateProject is targetPath then
                    return candidateDocument
                  end if
                end repeat
              end try
            end repeat
          end tell
          error "Workspace document not found"
        end workspaceDocumentForPath

        on joinList(items, delimiter)
          set previousDelimiters to AppleScript's text item delimiters
          set AppleScript's text item delimiters to delimiter
          set joinedText to items as text
          set AppleScript's text item delimiters to previousDelimiters
          return joinedText
        end joinList

        on optionalText(value)
          try
            if value is missing value then
              return ""
            end if
            return value as text
          on error
            return ""
          end try
        end optionalText

        on run argv
          set targetPath to item 1 of argv
          set fieldSeparator to ASCII character 31
          set recordSeparator to ASCII character 30
          set xdoc to my workspaceDocumentForPath(targetPath)

          tell application "Xcode"
            set outputRecords to {}
            repeat with r in run destinations of xdoc
              set d to device of r
              set outputFields to {name of r, platform of r, architecture of r, name of d, my optionalText(device model of d), my optionalText(operating system version of d), (generic of d as text)}
              set end of outputRecords to my joinList(outputFields, fieldSeparator)
            end repeat
            return my joinList(outputRecords, recordSeparator)
          end tell
        end run
        """
    }

    private static func makeSetScript() -> String {
        """
        on workspaceDocumentForPath(targetPath)
          tell application "Xcode"
            repeat with candidateDocument in workspace documents
              try
                if path of candidateDocument is targetPath then
                  return candidateDocument
                end if
              end try

              try
                repeat with candidateProject in projects of candidateDocument
                  if path of candidateProject is targetPath then
                    return candidateDocument
                  end if
                end repeat
              end try
            end repeat
          end tell
          error "Workspace document not found"
        end workspaceDocumentForPath

        on optionalText(value)
          try
            if value is missing value then
              return ""
            end if
            return value as text
          on error
            return ""
          end try
        end optionalText

        on run argv
          set targetPath to item 1 of argv
          set targetName to item 2 of argv
          set targetPlatform to item 3 of argv
          set targetArchitecture to item 4 of argv
          set targetDeviceName to item 5 of argv
          set targetDeviceModel to item 6 of argv
          set targetOSVersion to item 7 of argv
          set targetGeneric to item 8 of argv
          set xdoc to my workspaceDocumentForPath(targetPath)

          tell application "Xcode"
            set matchedDestination to missing value
            repeat with candidateDestination in run destinations of xdoc
              set candidateDevice to device of candidateDestination
              set candidateName to name of candidateDestination
              set candidatePlatform to platform of candidateDestination
              set candidateArchitecture to architecture of candidateDestination
              set candidateDeviceName to name of candidateDevice
              set candidateDeviceModel to my optionalText(device model of candidateDevice)
              set candidateOSVersion to my optionalText(operating system version of candidateDevice)
              set candidateGeneric to (generic of candidateDevice as text)

              if candidateName is targetName and candidatePlatform is targetPlatform and candidateArchitecture is targetArchitecture and candidateDeviceName is targetDeviceName and candidateDeviceModel is targetDeviceModel and candidateOSVersion is targetOSVersion and candidateGeneric is targetGeneric then
                set matchedDestination to candidateDestination
                exit repeat
              end if
            end repeat

            if matchedDestination is missing value then
              error "Run destination not found"
            end if

            set active run destination of xdoc to matchedDestination
            return "OK"
          end tell
        end run
        """
    }
}

private enum SelectionKeyComponent: Comparable {
    case int(Int)
    case string(String)

    static func < (lhs: SelectionKeyComponent, rhs: SelectionKeyComponent) -> Bool {
        switch (lhs, rhs) {
        case let (.int(lhsValue), .int(rhsValue)):
            return lhsValue < rhsValue
        case let (.string(lhsValue), .string(rhsValue)):
            return lhsValue < rhsValue
        case (.int, .string):
            return true
        case (.string, .int):
            return false
        }
    }
}

private extension Array where Element == SelectionKeyComponent {
    func lexicographicallyPrecedes(_ other: [SelectionKeyComponent]) -> Bool {
        self.lexicographicallyPrecedes(other, by: <)
    }
}
