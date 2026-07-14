import ApplicationServices
import Foundation
import Logging
import Testing
import XcodeMCPCoreTestSupport

@testable import XcodeMCPPermissionAutomation

@Suite(.serialized)
struct XcodePermissionDialogAutoApproverTests {
    @Test func matcherMatchesWhenSingleTextNodeContainsAssistantNameAndPID() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "Access",
            textValues: [
                "The agent XcodeMCPKit, PID 6119 wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision?.fingerprint.isEmpty == false)
        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherMatchesWhenConfiguredAssistantNameAndPIDShareATextNode() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.ExternalViewService",
            title: "許可",
            textValues: [
                "The agent Custom MCP, PID 4317 wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 500,
            assistantNameCandidates: ["Custom MCP"],
            serverProcessIDCandidates: [4317]
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherMatchesLocalizedAllowDialogThatContainsAssistantNameWithoutPID() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "エージェント XcodeMCPKit が Xcode のツール使用を要求しています。"
            ],
            defaultButton: makeButton(title: "許可")
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision?.defaultButtonTitle == "許可")
    }

    @Test func matcherMatchesAssistantNameWithoutPIDWhenAllowButtonUsesFallbackIdentifier() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "Allow",
            textValues: [
                "The agent XcodeMCPKit wants to use Xcode's tools."
            ],
            defaultButton: XcodePermissionDialogAutomation.ButtonSnapshot(
                role: "AXButton",
                identifier: "action-button-1"
            )
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision?.defaultButtonTitle == "action-button-1")
    }

    @Test func matcherRejectsLocalizedAllowDialogWithMismatchedProcessIdentifier() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "エージェント XcodeMCPKit、プロセス識別子 7001 が Xcode のツール使用を要求しています。"
            ],
            defaultButton: makeButton(title: "許可")
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func matcherRejectsPathDialogWithLocalizedMismatchedProcessIdentifier() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "エージェント XcodeMCPKit at /tmp/xcode-mcp-proxy-server、プロセス ID 7001 が Xcode のツール使用を要求しています。"
            ],
            defaultButton: makeButton(title: "許可")
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            agentPathCandidates: ["/tmp/xcode-mcp-proxy-server"],
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func matcherRejectsDialogThatContainsAssistantNameWithoutPIDWhenDefaultButtonIsNotAllow() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "エージェント XcodeMCPKit が Xcode のツール使用を要求しています。"
            ],
            defaultButton: makeButton(title: "OK")
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func matcherRejectsDialogThatContainsPIDWithoutAssistantName() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "The agent, PID 6119 wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func matcherMatchesDialogWhenAssistantNameAndPIDAppearInDifferentNodes() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "The agent XcodeMCPKit wants to use Xcode's tools.",
                "PID 6119",
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherMatchesDeveloperSystemPolicyDialogWithTitleNameAndBodyPID() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode.DeveloperSystemPolicyService",
            title: #"Allow "XcodeMCPKit" to access Xcode?"#,
            textValues: [
                "The agent wants to use Xcode's tools to perform actions like building, testing, or modifying code.",
                "Path: /Users/kn/Dev/XcodeMCPKit/.build/arm64-apple-macosx/debug/xcode-mcp-proxy-server",
                "PID: 23474",
                "Signed by: xcode-mcp-proxy-server-55554944e4908a045cea3fc2aa2f6e03b9059810",
            ],
            defaultButton: makeButton(title: "Allow")
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 1036,
            agentPathCandidates: [
                "/Users/kn/Dev/XcodeMCPKit/.build/arm64-apple-macosx/debug/xcode-mcp-proxy-server"
            ],
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [23474]
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherMatchesWhenAnyPIDCandidateSharesAWindowWithAssistantName() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "The agent XcodeMCPKit wants to use Xcode's tools.",
                "PID 7001",
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119, 7001]
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherRejectsPIDSubstringMatchesInsideLargerNumbers() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "The agent XcodeMCPKit, PID 16119 wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func matcherMatchesWhenAssistantNameAndAgentPathAppearWithoutPID() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "The agent XcodeMCPKit at /tmp/xcode-mcp-proxy-server wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            agentPathCandidates: ["/tmp/xcode-mcp-proxy-server"],
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherMatchesWhenAgentPathAppearsAndAssistantNameCandidatesAreEmpty() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "許可",
            textValues: [
                "The agent at /tmp/xcode-mcp-proxy-server wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            agentPathCandidates: ["/tmp/xcode-mcp-proxy-server"],
            assistantNameCandidates: [],
            serverProcessIDCandidates: []
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherRejectsEnglishCopyWithoutAssistantNameAndPID() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "Allow access",
            textValues: [
                "The agent wants to use Xcode's tools."
            ]
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func matcherRejectsNormalWorkspaceWindowEvenWhenTextContainsAssistantNameAndPID() {
        let snapshot = makeSnapshot(
            processBundleIdentifier: "com.apple.dt.Xcode",
            title: "Project",
            textValues: [
                "XcodeMCPKit PID 6119"
            ],
            subrole: "AXStandardWindow",
            isMain: true,
            document: "file:///tmp/Project.xcodeproj",
            hasProxy: true
        )

        let decision = XcodePermissionDialogAutomation.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func openWindowsFailureClassifierTreatsExternalViewServiceAXWindowsCannotCompleteAsBenign() {
        let isBenign = XcodePermissionDialogAutomation.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialogAutomation.AXError.copyAttributeFailed(
                attribute: kAXWindowsAttribute as String,
                error: .cannotComplete
            ),
            processBundleIdentifier: "com.apple.dt.ExternalViewService"
        )

        #expect(isBenign)
    }

    @Test func openWindowsFailureClassifierTreatsXcodeAXWindowsCannotCompleteAsBenign() {
        let isBenign = XcodePermissionDialogAutomation.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialogAutomation.AXError.copyAttributeFailed(
                attribute: kAXWindowsAttribute as String,
                error: .cannotComplete
            ),
            processBundleIdentifier: "com.apple.dt.Xcode"
        )

        #expect(isBenign)
    }

    @Test func openWindowsFailureClassifierRejectsExternalViewServiceForDifferentAttribute() {
        let isBenign = XcodePermissionDialogAutomation.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialogAutomation.AXError.copyAttributeFailed(
                attribute: kAXTitleAttribute as String,
                error: .cannotComplete
            ),
            processBundleIdentifier: "com.apple.dt.ExternalViewService"
        )

        #expect(isBenign == false)
    }

    @Test func openWindowsFailureClassifierRejectsExternalViewServiceForDifferentAXError() {
        let isBenign = XcodePermissionDialogAutomation.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialogAutomation.AXError.copyAttributeFailed(
                attribute: kAXWindowsAttribute as String,
                error: .attributeUnsupported
            ),
            processBundleIdentifier: "com.apple.dt.ExternalViewService"
        )

        #expect(isBenign == false)
    }

    @Test func executablePathCandidatesIncludeRawAndResolvedExecutablePaths() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("xcode-mcp-auto-approver-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let realExecutable = temporaryDirectory.appendingPathComponent("real-server")
        #expect(fileManager.createFile(atPath: realExecutable.path, contents: Data()))
        let symlinkExecutable = temporaryDirectory.appendingPathComponent("link-server")
        try fileManager.createSymbolicLink(at: symlinkExecutable, withDestinationURL: realExecutable)

        let candidates = XcodePermissionDialogAutomation.AutoApprover.executablePathCandidates(
            arguments: [symlinkExecutable.path],
            executableURL: realExecutable
        )

        #expect(candidates.contains(symlinkExecutable.path))
        #expect(candidates.contains(realExecutable.path))
    }

    @Test func scannerPromptsAccessibilityOnceAndRemainsInactiveWhenUntrusted() {
        let axClient = RecordingAXClient(status: .untrusted)
        var scanner = PermissionDialogScanner(
            dependencies: .init(
                configuration: .init(
                    permissionDialogProcessIDs: { axClient.recordedProcessIDs() },
                    agentPathCandidates: { ["/tmp/xcode-mcp-proxy-server"] },
                    assistantNameCandidates: { [] },
                    agentProcessIDCandidates: { [6119] }
                ),
                axClient: axClient,
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )

        #expect(scanner.scanAndApprove() == .untrusted)
        #expect(scanner.scanAndApprove() == .untrusted)

        let snapshot = axClient.snapshot()
        #expect(snapshot.promptCalls == 1)
        #expect(snapshot.windowScanCalls == 0)
    }

    @Test func scannerApprovesMatchingDialogsForEveryRunningXcodeInOneScan() {
        let firstProcessID: pid_t = 4316
        let secondProcessID: pid_t = 4317
        let axClient = RecordingAXClient(
            status: .trusted,
            windowsByProcessID: [
                firstProcessID: [
                    XcodePermissionDialogAutomation.AXWindow(
                        processID: firstProcessID,
                        snapshot: makeSnapshot(
                            processBundleIdentifier: "com.apple.dt.Xcode",
                            title: "Access",
                            textValues: ["XcodeMCPKit PID 6119"]
                        ),
                        defaultButton: AXUIElementCreateSystemWide()
                    )
                ],
                secondProcessID: [
                    XcodePermissionDialogAutomation.AXWindow(
                        processID: secondProcessID,
                        snapshot: makeSnapshot(
                            processBundleIdentifier: "com.apple.dt.Xcode",
                            title: "Access",
                            textValues: ["XcodeMCPKit PID 6119"]
                        ),
                        defaultButton: AXUIElementCreateSystemWide()
                    )
                ],
            ]
        )
        var scanner = PermissionDialogScanner(
            dependencies: .init(
                configuration: .init(
                    permissionDialogProcessIDs: { [firstProcessID, secondProcessID] },
                    agentPathCandidates: { [] },
                    assistantNameCandidates: { ["XcodeMCPKit"] },
                    agentProcessIDCandidates: { [6119] }
                ),
                axClient: axClient,
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )

        let result = scanner.scanAndApprove()

        #expect(result.inspectedProcessCount == 2)
        #expect(result.matchedWindowCount == 2)
        #expect(result.approvedWindowCount == 2)
        #expect(axClient.snapshot().pressCalls == 2)
    }

    @Test func scannerDoesNotEnumerateChildProcessesForOrdinaryWindows() {
        let processID: pid_t = 4316
        let axClient = RecordingAXClient(
            status: .trusted,
            windowsByProcessID: [
                processID: [
                    XcodePermissionDialogAutomation.AXWindow(
                        processID: processID,
                        snapshot: makeSnapshot(
                            processBundleIdentifier: "com.apple.dt.Xcode",
                            title: "Workspace",
                            textValues: [],
                            subrole: "AXStandardWindow"
                        ),
                        defaultButton: AXUIElementCreateSystemWide()
                    )
                ]
            ]
        )
        let childProcessScanCount = CallCounter()
        var scanner = PermissionDialogScanner(
            dependencies: .init(
                configuration: .init(
                    permissionDialogProcessIDs: { axClient.recordedProcessIDs() },
                    agentPathCandidates: { [] },
                    assistantNameCandidates: { ["XcodeMCPKit"] },
                    agentProcessIDCandidates: {
                        childProcessScanCount.increment()
                        return []
                    }
                ),
                axClient: axClient,
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )

        let result = scanner.scanAndApprove()

        #expect(result.inspectedWindowCount == 1)
        #expect(axClient.snapshot().windowScanCalls == 1)
        #expect(childProcessScanCount.value() == 0)
    }

    @Test func scannerRefreshesAgentPathCandidatesBetweenScans() {
        let processID: pid_t = 4317
        let bridgePath = "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
        let axClient = RecordingAXClient(
            status: .trusted,
            windowsByProcessID: [
                processID: [
                    XcodePermissionDialogAutomation.AXWindow(
                        processID: processID,
                        snapshot: makeSnapshot(
                            processBundleIdentifier: "com.apple.dt.Xcode",
                            title: "Access",
                            textValues: [
                                "The agent at \(bridgePath) wants to use Xcode's tools for XcodeMCPKit."
                            ]
                        ),
                        defaultButton: AXUIElementCreateSystemWide()
                    )
                ]
            ]
        )
        let candidateCounter = CandidateCounter()
        var scanner = PermissionDialogScanner(
            dependencies: .init(
                configuration: .init(
                    permissionDialogProcessIDs: { axClient.recordedProcessIDs() },
                    agentPathCandidates: {
                        candidateCounter.nextCandidateSet(first: [], later: [bridgePath])
                    },
                    assistantNameCandidates: { [] },
                    agentProcessIDCandidates: { [] }
                ),
                axClient: axClient,
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )

        #expect(scanner.scanAndApprove().approvedWindowCount == 0)
        #expect(scanner.scanAndApprove().approvedWindowCount == 1)
        #expect(axClient.snapshot().pressCalls == 1)
    }

    @Test func scannerSuppressesRepeatedPressesUntilTheRetryIntervalElapses() {
        let processID: pid_t = 4318
        let uptimeClock = RecordingUptimeClock()
        let axClient = RecordingAXClient(
            status: .trusted,
            windowsByProcessID: [
                processID: [
                    XcodePermissionDialogAutomation.AXWindow(
                        processID: processID,
                        snapshot: makeSnapshot(
                            processBundleIdentifier: "com.apple.dt.Xcode",
                            title: "Access",
                            textValues: ["XcodeMCPKit 6119"]
                        ),
                        defaultButton: AXUIElementCreateSystemWide()
                    )
                ]
            ]
        )
        var scanner = PermissionDialogScanner(
            dependencies: .init(
                configuration: .init(
                    permissionDialogProcessIDs: { [processID] },
                    agentPathCandidates: { [] },
                    assistantNameCandidates: { ["XcodeMCPKit"] },
                    agentProcessIDCandidates: { [6119] }
                ),
                axClient: axClient,
                uptimeNanoseconds: { uptimeClock.now() },
                logger: Logger(label: "tests.permission")
            )
        )

        #expect(scanner.scanAndApprove().approvedWindowCount == 1)
        uptimeClock.set(499_999_999)
        #expect(scanner.scanAndApprove().approvedWindowCount == 0)
        uptimeClock.set(500_000_000)
        #expect(scanner.scanAndApprove().approvedWindowCount == 1)
        #expect(axClient.snapshot().pressCalls == 2)
    }

    @Test func autoApproverShutdownAwaitsItsPollTask() async throws {
        let axClient = RecordingAXClient(status: .trusted)
        let clock = TestClock()
        let configuration = XcodePermissionDialogAutomation.Configuration(
            permissionDialogProcessIDs: { axClient.recordedProcessIDs() },
            agentPathCandidates: { [] },
            assistantNameCandidates: { ["XcodeMCPKit"] },
            agentProcessIDCandidates: { [] },
            pollInterval: .seconds(1)
        )
        let approver = XcodePermissionDialogAutomation.AutoApprover(
            configuration: configuration,
            dependencies: .init(
                axClient: axClient,
                sleep: { duration in
                    try await clock.sleep(for: duration)
                },
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )
        approver.start()
        approver.start()
        try await clock.sleep(untilSuspendedBy: 1)
        await approver.shutdown()
        await approver.shutdown()

        #expect(axClient.snapshot().windowScanCalls == 1)
    }

    @Test func blockedHelperInspectionDoesNotDelayAnotherXcodeDialog() async throws {
        let helperProcessID: pid_t = 100
        let xcodeProcessID: pid_t = 200
        let approvals = RecordedValues<pid_t>()
        let axClient = BlockingHelperAXClient(
            helperProcessID: helperProcessID,
            xcodeProcessID: xcodeProcessID,
            xcodeWindow: XcodePermissionDialogAutomation.AXWindow(
                processID: xcodeProcessID,
                snapshot: makeSnapshot(
                    processBundleIdentifier: "com.apple.dt.Xcode",
                    title: "Access",
                    textValues: ["XcodeMCPKit PID 6119"]
                ),
                defaultButton: AXUIElementCreateSystemWide()
            ),
            approvals: approvals
        )
        let clock = TestClock()
        let approver = XcodePermissionDialogAutomation.AutoApprover(
            configuration: .init(
                permissionDialogProcessIDs: { [helperProcessID, xcodeProcessID] },
                agentPathCandidates: { [] },
                assistantNameCandidates: { ["XcodeMCPKit"] },
                agentProcessIDCandidates: { [6119] },
                pollInterval: .seconds(1)
            ),
            dependencies: .init(
                axClient: axClient,
                sleep: { duration in
                    try await clock.sleep(for: duration)
                },
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )
        defer {
            axClient.releaseHelperInspection()
            approver.cancel()
        }

        approver.start()
        let approvedProcessID = try await waitWithTimeout(
            "waiting for Xcode approval while helper AX inspection is blocked"
        ) {
            try await approvals.nextValue(at: 0)
        }
        axClient.releaseHelperInspection()
        await approver.shutdown()

        #expect(approvedProcessID == xcodeProcessID)
    }

    @Test func removedAndReaddedPIDDoesNotOverlapCancelledMonitor() async throws {
        let processID: pid_t = 100
        let processInventory = MutableProcessInventory([processID])
        let inspections = RecordedValues<Int>()
        let axClient = BlockingProcessAXClient(
            processID: processID,
            inspections: inspections
        )
        let clock = TestClock()
        let approver = XcodePermissionDialogAutomation.AutoApprover(
            configuration: .init(
                permissionDialogProcessIDs: { processInventory.snapshot() },
                agentPathCandidates: { [] },
                assistantNameCandidates: { ["XcodeMCPKit"] },
                agentProcessIDCandidates: { [] },
                pollInterval: .seconds(1)
            ),
            dependencies: .init(
                axClient: axClient,
                sleep: { duration in
                    try await clock.sleep(for: duration)
                },
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )
        defer {
            axClient.releaseInspection()
            approver.cancel()
        }

        approver.start()
        _ = try await waitWithTimeout("waiting for the first PID inspection") {
            try await inspections.nextValue(at: 0)
        }
        try await clock.sleep(untilSuspendedBy: 1)

        processInventory.replace(with: [])
        clock.advance(by: .seconds(1))
        try await clock.sleep(untilSuspendedBy: 1)

        processInventory.replace(with: [processID])
        clock.advance(by: .seconds(1))
        try await clock.sleep(untilSuspendedBy: 1)

        #expect(axClient.inspectionCount == 1)

        axClient.releaseInspection()
        await approver.shutdown()
    }

    @Test func autoApproverPromptsAccessibilityOnceAcrossProcessMonitors() async throws {
        let axClient = RecordingAXClient(status: .untrusted)
        let clock = TestClock()
        let approver = XcodePermissionDialogAutomation.AutoApprover(
            configuration: .init(
                permissionDialogProcessIDs: { [100, 200] },
                agentPathCandidates: { [] },
                assistantNameCandidates: { ["XcodeMCPKit"] },
                agentProcessIDCandidates: { [] },
                pollInterval: .seconds(1)
            ),
            dependencies: .init(
                axClient: axClient,
                sleep: { duration in
                    try await clock.sleep(for: duration)
                },
                uptimeNanoseconds: { 0 },
                logger: Logger(label: "tests.permission")
            )
        )

        approver.start()
        try await clock.sleep(untilSuspendedBy: 3)
        await approver.shutdown()

        #expect(axClient.snapshot().promptCalls == 1)
    }

    @Test func autoApproverPollTaskDoesNotRetainItsOwner() async throws {
        let axClient = RecordingAXClient(status: .trusted)
        let clock = TestClock()
        weak var retainedApprover: XcodePermissionDialogAutomation.AutoApprover?

        do {
            let approver = XcodePermissionDialogAutomation.AutoApprover(
                configuration: .init(
                    permissionDialogProcessIDs: { [] },
                    agentPathCandidates: { [] },
                    assistantNameCandidates: { [] },
                    agentProcessIDCandidates: { [] },
                    pollInterval: .seconds(1)
                ),
                dependencies: .init(
                    axClient: axClient,
                    sleep: { duration in
                        try await clock.sleep(for: duration)
                    },
                    uptimeNanoseconds: { 0 },
                    logger: Logger(label: "tests.permission")
                )
            )
            retainedApprover = approver
            approver.start()
            try await clock.sleep(untilSuspendedBy: 1)
        }

        #expect(retainedApprover == nil)
    }
}

private func makeSnapshot(
    processBundleIdentifier: String,
    title: String,
    textValues: [String],
    role: String = "AXWindow",
    subrole: String = "AXDialog",
    windowIdentifier: String? = nil,
    isModal: Bool = true,
    isMain: Bool? = false,
    isMinimized: Bool? = false,
    document: String? = nil,
    childCount: Int = 3,
    hasProxy: Bool = false,
    defaultButton: XcodePermissionDialogAutomation.ButtonSnapshot? = makeButton(title: "Allow"),
    cancelButton: XcodePermissionDialogAutomation.ButtonSnapshot? = makeButton(title: "Cancel")
) -> XcodePermissionDialogAutomation.WindowSnapshot {
    XcodePermissionDialogAutomation.WindowSnapshot(
        processBundleIdentifier: processBundleIdentifier,
        title: title,
        textValues: textValues,
        role: role,
        subrole: subrole,
        windowIdentifier: windowIdentifier,
        isModal: isModal,
        isMain: isMain,
        isMinimized: isMinimized,
        document: document,
        childCount: childCount,
        hasProxy: hasProxy,
        defaultButton: defaultButton,
        cancelButton: cancelButton
    )
}

private func makeButton(
    title: String,
    role: String = "AXButton",
    subrole: String? = nil,
    identifier: String? = nil
) -> XcodePermissionDialogAutomation.ButtonSnapshot {
    XcodePermissionDialogAutomation.ButtonSnapshot(
        title: title,
        role: role,
        subrole: subrole,
        identifier: identifier
    )
}

private final class RecordingAXClient: @unchecked Sendable, XcodePermissionDialogAutomation.AXAccessing {
    private let status: XcodePermissionDialogAutomation.AccessibilityStatus
    private let windowsByProcessID: [pid_t: [XcodePermissionDialogAutomation.AXWindow]]
    private let lock = NSLock()
    private var promptCalls = 0
    private var windowScanCalls = 0
    private var pressCalls = 0

    init(
        status: XcodePermissionDialogAutomation.AccessibilityStatus,
        windowsByProcessID: [pid_t: [XcodePermissionDialogAutomation.AXWindow]] = [:]
    ) {
        self.status = status
        self.windowsByProcessID = windowsByProcessID
    }

    func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialogAutomation.AccessibilityStatus {
        lock.withLock {
            if promptIfNeeded {
                promptCalls += 1
            }
            return status
        }
    }

    func recordedProcessIDs() -> [pid_t] {
        lock.withLock {
            windowScanCalls += 1
            return windowsByProcessID.keys.sorted()
        }
    }

    func openWindows(for processID: pid_t) throws -> [XcodePermissionDialogAutomation.AXWindow] {
        windowsByProcessID[processID] ?? []
    }

    func pressDefaultButton(in window: XcodePermissionDialogAutomation.AXWindow) throws {
        lock.withLock {
            pressCalls += 1
        }
    }

    func snapshot() -> (promptCalls: Int, windowScanCalls: Int, pressCalls: Int) {
        lock.withLock {
            (promptCalls, windowScanCalls, pressCalls)
        }
    }
}

private final class BlockingHelperAXClient: @unchecked Sendable,
    XcodePermissionDialogAutomation.AXAccessing
{
    private let helperProcessID: pid_t
    private let xcodeProcessID: pid_t
    private let xcodeWindow: XcodePermissionDialogAutomation.AXWindow
    private let approvals: RecordedValues<pid_t>
    private let helperInspectionStarted = DispatchSemaphore(value: 0)
    private let helperInspectionRelease = DispatchSemaphore(value: 0)

    init(
        helperProcessID: pid_t,
        xcodeProcessID: pid_t,
        xcodeWindow: XcodePermissionDialogAutomation.AXWindow,
        approvals: RecordedValues<pid_t>
    ) {
        self.helperProcessID = helperProcessID
        self.xcodeProcessID = xcodeProcessID
        self.xcodeWindow = xcodeWindow
        self.approvals = approvals
    }

    func authorizationStatus(promptIfNeeded _: Bool)
        -> XcodePermissionDialogAutomation.AccessibilityStatus
    {
        .trusted
    }

    func openWindows(for processID: pid_t) throws
        -> [XcodePermissionDialogAutomation.AXWindow]
    {
        switch processID {
        case helperProcessID:
            helperInspectionStarted.signal()
            helperInspectionRelease.wait()
            return []
        case xcodeProcessID:
            helperInspectionStarted.wait()
            return [xcodeWindow]
        default:
            return []
        }
    }

    func pressDefaultButton(in window: XcodePermissionDialogAutomation.AXWindow) throws {
        let processID = window.processID
        Task {
            await approvals.append(processID)
        }
    }

    func releaseHelperInspection() {
        helperInspectionRelease.signal()
    }
}

private final class BlockingProcessAXClient: @unchecked Sendable,
    XcodePermissionDialogAutomation.AXAccessing
{
    private let processID: pid_t
    private let inspections: RecordedValues<Int>
    private let inspectionRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inspectionCountStorage = 0

    init(processID: pid_t, inspections: RecordedValues<Int>) {
        self.processID = processID
        self.inspections = inspections
    }

    var inspectionCount: Int {
        lock.withLock { inspectionCountStorage }
    }

    func authorizationStatus(promptIfNeeded _: Bool)
        -> XcodePermissionDialogAutomation.AccessibilityStatus
    {
        .trusted
    }

    func openWindows(for processID: pid_t) throws
        -> [XcodePermissionDialogAutomation.AXWindow]
    {
        #expect(processID == self.processID)
        let inspection = lock.withLock {
            inspectionCountStorage += 1
            return inspectionCountStorage
        }
        Task {
            await inspections.append(inspection)
        }
        if inspection == 1 {
            inspectionRelease.wait()
        }
        return []
    }

    func pressDefaultButton(in _: XcodePermissionDialogAutomation.AXWindow) throws {}

    func releaseInspection() {
        inspectionRelease.signal()
    }
}

private final class MutableProcessInventory: @unchecked Sendable {
    private let lock = NSLock()
    private var processIDs: [pid_t]

    init(_ processIDs: [pid_t]) {
        self.processIDs = processIDs
    }

    func snapshot() -> [pid_t] {
        lock.withLock { processIDs }
    }

    func replace(with processIDs: [pid_t]) {
        lock.withLock {
            self.processIDs = processIDs
        }
    }
}

private final class CandidateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func nextCandidateSet(first: Set<String>, later: Set<String>) -> Set<String> {
        lock.withLock {
            count += 1
            return count == 1 ? first : later
        }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock {
            count += 1
        }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private final class RecordingUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock { value }
    }

    func set(_ value: UInt64) {
        lock.withLock { self.value = value }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
