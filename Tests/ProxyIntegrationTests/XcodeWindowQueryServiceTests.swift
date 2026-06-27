import Testing

@testable import ProxySession

@Suite
struct XcodeWindowQueryServiceTests {
    @Test func windowQueryServicePreservesLiteralWhitespaceInParsedFields() {
        let service = XcodeWindowQueryService()
        let windows = service.parseXcodeListWindowsMessage(
            "* tabIdentifier: tab-id  , workspacePath: /tmp/Workspace \n"
        )

        #expect(windows == [
            XcodeWindowInfo(
                tabIdentifier: "tab-id  ",
                workspacePath: "/tmp/Workspace "
            )
        ])
    }

    @Test func windowQueryServiceParsesCommaContainingFields() {
        let service = XcodeWindowQueryService()
        let windows = service.parseXcodeListWindowsMessage(
            "* tabIdentifier: tab,id, workspacePath: /tmp/Work,space\n"
        )

        #expect(windows == [
            XcodeWindowInfo(
                tabIdentifier: "tab,id",
                workspacePath: "/tmp/Work,space"
            )
        ])
    }

    @Test func windowQueryServiceParsesIndentedWindowLines() {
        let service = XcodeWindowQueryService()
        let windows = service.parseXcodeListWindowsMessage(
            "  \t* tabIdentifier: tab-2, workspacePath: /tmp/Indented\n"
        )

        #expect(windows == [
            XcodeWindowInfo(
                tabIdentifier: "tab-2",
                workspacePath: "/tmp/Indented"
            )
        ])
    }

    @Test func windowQueryServiceScansAllTextItemsForMessagePayload() {
        let service = XcodeWindowQueryService()
        let message = service.extractToolMessage(
            from: [
                "content": [
                    ["type": "text", "text": "preamble"],
                    ["type": "text", "text": "{\"message\":\"* tabIdentifier: tab-1, workspacePath: /tmp/Workspace\"}"],
                ]
            ]
        )

        #expect(message == "* tabIdentifier: tab-1, workspacePath: /tmp/Workspace")
    }
}
