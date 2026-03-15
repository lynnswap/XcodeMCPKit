import Foundation
import Testing

@testable import ProxyFeatureXcode
@testable import ProxyRuntime

@Suite
struct XcodeRunDestinationServiceTests {
    @Test func serviceListsPlatformsAndDeviceFamilies() async throws {
        let workspacePath = makeRunDestinationWorkspacePath()
        let runner = StubProcessRunner { request in
            #expect(request.label == "xcode-list-run-destinations")
            return ProcessOutput(
                terminationStatus: 0,
                stdout: makeRunDestinationListOutput([
                    (
                        name: "iPhone 17",
                        platform: "iphonesimulator",
                        architecture: "arm64",
                        deviceName: "iPhone 17",
                        deviceModel: "iPhone 17",
                        osVersion: "26.2",
                        generic: false
                    ),
                    (
                        name: "iPad Pro 11-inch (M5)",
                        platform: "iphonesimulator",
                        architecture: "arm64",
                        deviceName: "iPad Pro 11-inch (M5)",
                        deviceModel: "iPad Pro 11-inch (M5)",
                        osVersion: "26.2",
                        generic: false
                    ),
                    (
                        name: "Any iOS Simulator Device (arm64, arm64_32, x86_64)",
                        platform: "iphonesimulator",
                        architecture: "undefined_arch",
                        deviceName: "Any iOS Simulator Device",
                        deviceModel: "Apple device",
                        osVersion: nil,
                        generic: true
                    ),
                ]),
                stderr: ""
            )
        }
        let service = XcodeRunDestinationService(processRunner: runner)

        let result = await service.listRunDestinations(workspacePath: workspacePath)
        guard case .success(let output) = result else {
            Issue.record("expected success")
            return
        }

        #expect(output.platforms.count == 1)
        #expect(output.platforms[0].id == "ios-simulator")
        #expect(output.platforms[0].osVersions == ["26.2"])
        #expect(output.platforms[0].deviceFamilies == ["iphone", "ipad", "generic"])
        #expect(output.destinations.first?.deviceFamily == "iphone")
    }

    @Test func serviceSelectsIPhoneWhenFamilyIsOmitted() async throws {
        let workspacePath = makeRunDestinationWorkspacePath()
        let runner = StubProcessRunner { request in
            switch request.label {
            case "xcode-list-run-destinations":
                return ProcessOutput(
                    terminationStatus: 0,
                    stdout: makeRunDestinationListOutput([
                        (
                            name: "iPhone 17",
                            platform: "iphonesimulator",
                            architecture: "arm64",
                            deviceName: "iPhone 17",
                            deviceModel: "iPhone 17",
                            osVersion: "26.2",
                            generic: false
                        ),
                        (
                            name: "iPad Pro 11-inch (M5)",
                            platform: "iphonesimulator",
                            architecture: "arm64",
                            deviceName: "iPad Pro 11-inch (M5)",
                            deviceModel: "iPad Pro 11-inch (M5)",
                            osVersion: "26.2",
                            generic: false
                        ),
                        (
                            name: "iPhone 17 (Rosetta)",
                            platform: "iphonesimulator",
                            architecture: "x86_64",
                            deviceName: "iPhone 17",
                            deviceModel: "iPhone 17",
                            osVersion: "26.2",
                            generic: false
                        ),
                    ]),
                    stderr: ""
                )
            case "xcode-set-active-run-destination":
                #expect(
                    request.arguments == [
                        "-",
                        workspacePath,
                        "iPhone 17",
                        "iphonesimulator",
                        "arm64",
                        "iPhone 17",
                        "iPhone 17",
                        "26.2",
                        "false",
                    ]
                )
                return ProcessOutput(terminationStatus: 0, stdout: "OK", stderr: "")
            default:
                return ProcessOutput(terminationStatus: 1, stdout: "", stderr: "unexpected")
            }
        }
        let service = XcodeRunDestinationService(processRunner: runner)

        let result = await service.setActiveRunDestination(
            workspacePath: workspacePath,
            platform: "ios-simulator",
            osVersion: "26.2",
            deviceFamily: nil
        )
        guard case .success(let output) = result else {
            Issue.record("expected success")
            return
        }

        #expect(output.selectedDestination.name == "iPhone 17")
        #expect(output.selectedDestination.deviceFamily == "iphone")
        #expect(output.setterAccepted == true)
        #expect(output.readBackUnavailable == true)
    }

    @Test func serviceSelectsIPadWhenFamilyIsSpecified() async throws {
        let workspacePath = makeRunDestinationWorkspacePath()
        let runner = StubProcessRunner { request in
            switch request.label {
            case "xcode-list-run-destinations":
                return ProcessOutput(
                    terminationStatus: 0,
                    stdout: makeRunDestinationListOutput([
                        (
                            name: "iPhone 17",
                            platform: "iphonesimulator",
                            architecture: "arm64",
                            deviceName: "iPhone 17",
                            deviceModel: "iPhone 17",
                            osVersion: "26.2",
                            generic: false
                        ),
                        (
                            name: "iPad Pro 11-inch (M5)",
                            platform: "iphonesimulator",
                            architecture: "arm64",
                            deviceName: "iPad Pro 11-inch (M5)",
                            deviceModel: "iPad Pro 11-inch (M5)",
                            osVersion: "26.2",
                            generic: false
                        ),
                    ]),
                    stderr: ""
                )
            case "xcode-set-active-run-destination":
                #expect(
                    request.arguments == [
                        "-",
                        workspacePath,
                        "iPad Pro 11-inch (M5)",
                        "iphonesimulator",
                        "arm64",
                        "iPad Pro 11-inch (M5)",
                        "iPad Pro 11-inch (M5)",
                        "26.2",
                        "false",
                    ]
                )
                return ProcessOutput(terminationStatus: 0, stdout: "OK", stderr: "")
            default:
                return ProcessOutput(terminationStatus: 1, stdout: "", stderr: "unexpected")
            }
        }
        let service = XcodeRunDestinationService(processRunner: runner)

        let result = await service.setActiveRunDestination(
            workspacePath: workspacePath,
            platform: "ios-simulator",
            osVersion: "26.2",
            deviceFamily: "ipad"
        )
        guard case .success(let output) = result else {
            Issue.record("expected success")
            return
        }

        #expect(output.selectedDestination.name == "iPad Pro 11-inch (M5)")
        #expect(output.selectedDestination.deviceFamily == "ipad")
    }

    @Test func serviceReturnsAvailableDeviceFamiliesOnFamilyMismatch() async throws {
        let workspacePath = makeRunDestinationWorkspacePath()
        let runner = StubProcessRunner { request in
            #expect(request.label == "xcode-list-run-destinations")
            return ProcessOutput(
                terminationStatus: 0,
                stdout: makeRunDestinationListOutput([
                    (
                        name: "iPhone 17",
                        platform: "iphonesimulator",
                        architecture: "arm64",
                        deviceName: "iPhone 17",
                        deviceModel: "iPhone 17",
                        osVersion: "26.2",
                        generic: false
                    ),
                    (
                        name: "iPad Pro 11-inch (M5)",
                        platform: "iphonesimulator",
                        architecture: "arm64",
                        deviceName: "iPad Pro 11-inch (M5)",
                        deviceModel: "iPad Pro 11-inch (M5)",
                        osVersion: "26.2",
                        generic: false
                    ),
                ]),
                stderr: ""
            )
        }
        let service = XcodeRunDestinationService(processRunner: runner)

        let result = await service.setActiveRunDestination(
            workspacePath: workspacePath,
            platform: "ios-simulator",
            osVersion: "26.2",
            deviceFamily: "mac"
        )

        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }

        #expect(error.message.contains("deviceFamily"))
        let availableFamilies = error.structuredContent["availableDeviceFamilies"]?.foundationObject as? [String]
        #expect(availableFamilies == ["iphone", "ipad"])
    }

    @Test func serviceAllowsSelectingVersionlessDestinationWithoutOSVersion() async throws {
        let workspacePath = makeRunDestinationWorkspacePath()
        let runner = StubProcessRunner { request in
            switch request.label {
            case "xcode-list-run-destinations":
                return ProcessOutput(
                    terminationStatus: 0,
                    stdout: makeRunDestinationListOutput([
                        (
                            name: "Any iOS Simulator Device (arm64, arm64_32, x86_64)",
                            platform: "iphonesimulator",
                            architecture: "undefined_arch",
                            deviceName: "Any iOS Simulator Device",
                            deviceModel: "Apple device",
                            osVersion: nil,
                            generic: true
                        )
                    ]),
                    stderr: ""
                )
            case "xcode-set-active-run-destination":
                #expect(
                    request.arguments == [
                        "-",
                        workspacePath,
                        "Any iOS Simulator Device (arm64, arm64_32, x86_64)",
                        "iphonesimulator",
                        "undefined_arch",
                        "Any iOS Simulator Device",
                        "Apple device",
                        "",
                        "true",
                    ]
                )
                return ProcessOutput(terminationStatus: 0, stdout: "OK", stderr: "")
            default:
                return ProcessOutput(terminationStatus: 1, stdout: "", stderr: "unexpected")
            }
        }
        let service = XcodeRunDestinationService(processRunner: runner)

        let result = await service.setActiveRunDestination(
            workspacePath: workspacePath,
            platform: "ios-simulator",
            osVersion: nil,
            deviceFamily: "generic"
        )

        guard case .success(let output) = result else {
            Issue.record("expected success")
            return
        }

        #expect(output.selectedDestination.generic == true)
        #expect(output.selectedDestination.osVersion == nil)
    }
}

private actor StubProcessRunner: ProcessRunning {
    private let handler: @Sendable (ProcessRequest) throws -> ProcessOutput

    init(handler: @escaping @Sendable (ProcessRequest) throws -> ProcessOutput) {
        self.handler = handler
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        try handler(request)
    }
}

private func makeRunDestinationListOutput(
    _ records: [(name: String, platform: String, architecture: String, deviceName: String, deviceModel: String?, osVersion: String?, generic: Bool)]
) -> String {
    let recordSeparator = "\u{001E}"
    let fieldSeparator = "\u{001F}"

    return records.map { record in
        [
            record.name,
            record.platform,
            record.architecture,
            record.deviceName,
            record.deviceModel ?? "",
            record.osVersion ?? "",
            record.generic ? "true" : "false",
        ].joined(separator: fieldSeparator)
    }.joined(separator: recordSeparator)
}

private func makeRunDestinationWorkspacePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("XcodeRunDestinationTests-\(UUID().uuidString)")
        .path
}
