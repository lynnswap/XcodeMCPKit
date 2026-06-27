import ApplicationServices
import Foundation
import Testing

@testable import ProxyCore
@testable import ProxyXcodeSupport

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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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
            defaultButton: XcodePermissionDialog.ButtonSnapshot(
                role: "AXButton",
                identifier: "action-button-1"
            )
        )

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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
                "PID 6119"
            ]
        )

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
            for: snapshot,
            processID: 1036,
            agentPathCandidates: [
                "/Users/kn/Dev/XcodeMCPKit/.build/arm64-apple-macosx/debug/xcode-mcp-proxy-server",
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
                "PID 7001"
            ]
        )

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
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

        let decision = XcodePermissionDialog.Matcher.decision(
            for: snapshot,
            processID: 4317,
            assistantNameCandidates: ["XcodeMCPKit"],
            serverProcessIDCandidates: [6119]
        )

        #expect(decision == nil)
    }

    @Test func openWindowsFailureClassifierTreatsExternalViewServiceAXWindowsCannotCompleteAsBenign() {
        let isBenign = XcodePermissionDialog.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialog.AXError.copyAttributeFailed(
                attribute: kAXWindowsAttribute as String,
                error: .cannotComplete
            ),
            processBundleIdentifier: "com.apple.dt.ExternalViewService"
        )

        #expect(isBenign)
    }

    @Test func openWindowsFailureClassifierRejectsXcodeAXWindowsCannotComplete() {
        let isBenign = XcodePermissionDialog.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialog.AXError.copyAttributeFailed(
                attribute: kAXWindowsAttribute as String,
                error: .cannotComplete
            ),
            processBundleIdentifier: "com.apple.dt.Xcode"
        )

        #expect(isBenign == false)
    }

    @Test func openWindowsFailureClassifierRejectsExternalViewServiceForDifferentAttribute() {
        let isBenign = XcodePermissionDialog.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialog.AXError.copyAttributeFailed(
                attribute: kAXTitleAttribute as String,
                error: .cannotComplete
            ),
            processBundleIdentifier: "com.apple.dt.ExternalViewService"
        )

        #expect(isBenign == false)
    }

    @Test func openWindowsFailureClassifierRejectsExternalViewServiceForDifferentAXError() {
        let isBenign = XcodePermissionDialog.AXFailureClassifier.isBenignOpenWindowsFailure(
            XcodePermissionDialog.AXError.copyAttributeFailed(
                attribute: kAXWindowsAttribute as String,
                error: .attributeUnsupported
            ),
            processBundleIdentifier: "com.apple.dt.ExternalViewService"
        )

        #expect(isBenign == false)
    }

    @Test func defaultAgentPathCandidatesIncludeRawAndResolvedExecutablePaths() throws {
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

        let candidates = XcodePermissionDialog.AutoApprover.defaultAgentPathCandidates(
            arguments: [symlinkExecutable.path],
            executableURL: realExecutable
        )

        #expect(candidates.contains(symlinkExecutable.path))
        #expect(candidates.contains(realExecutable.path))
    }

    @Test func autoApproverPromptsAccessibilityOnceAndRemainsInactiveWhenUntrusted() async {
        let axClient = RecordingAXClient(status: .untrusted)
        let approver = XcodePermissionDialog.AutoApprover(
            dependencies: .init(
                axClient: axClient,
                agentPathCandidates: { ["/tmp/xcode-mcp-proxy-server"] },
                assistantNameCandidates: { ["XcodeMCPKit"] },
                serverProcessIDCandidates: { [6119] },
                sleep: { _ in },
                pollInterval: .milliseconds(1),
                logger: ProxyLogging.make("tests.permission")
            )
        )

        approver.start()
        approver.start()
        approver.stop()

        let snapshot = axClient.snapshot()
        #expect(snapshot.promptCalls == 1)
        #expect(snapshot.windowScanCalls == 0)
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
    defaultButton: XcodePermissionDialog.ButtonSnapshot? = makeButton(title: "Allow"),
    cancelButton: XcodePermissionDialog.ButtonSnapshot? = makeButton(title: "Cancel")
) -> XcodePermissionDialog.WindowSnapshot {
    XcodePermissionDialog.WindowSnapshot(
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
) -> XcodePermissionDialog.ButtonSnapshot {
    XcodePermissionDialog.ButtonSnapshot(
        title: title,
        role: role,
        subrole: subrole,
        identifier: identifier
    )
}

private final class RecordingAXClient: @unchecked Sendable, XcodePermissionDialog.AXAccessing {
    private let status: XcodePermissionDialog.AccessibilityStatus
    private let lock = NSLock()
    private var promptCalls = 0
    private var windowScanCalls = 0

    init(status: XcodePermissionDialog.AccessibilityStatus) {
        self.status = status
    }

    func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialog.AccessibilityStatus {
        lock.withLock {
            if promptIfNeeded {
                promptCalls += 1
            }
            return status
        }
    }

    func runningXcodeProcessIDs() -> [pid_t] {
        lock.withLock {
            windowScanCalls += 1
            return []
        }
    }

    func openWindows(for processID: pid_t) throws -> [XcodePermissionDialog.AXWindow] {
        []
    }

    func pressDefaultButton(in window: XcodePermissionDialog.AXWindow) throws {}

    func snapshot() -> (promptCalls: Int, windowScanCalls: Int) {
        lock.withLock {
            (promptCalls, windowScanCalls)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
