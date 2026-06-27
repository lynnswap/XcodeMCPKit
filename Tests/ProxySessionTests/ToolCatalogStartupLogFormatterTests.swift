import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime
import Testing

@testable import XcodeMCPProxyKit

@Suite
struct ToolCatalogStartupLogFormatterTests {
    @Test func summaryListsAvailableToolsOnePerLine() throws {
        let result = try #require(JSONValue(any: [
            "tools": [
                ["name": "XcodeRead"],
                ["name": "DocumentationSearch"],
                ["name": "BuildProject"],
            ],
        ]))

        let summary = ToolCatalogStartupLogFormatter.summary(from: result)

        #expect(summary == """
        Tools
          DocumentationSearch: available
          Count: 3
          Available:
            - BuildProject
            - DocumentationSearch
            - XcodeRead
        """)
    }

    @Test func summaryMarksDocumentationSearchUnavailable() throws {
        let result = try #require(JSONValue(any: [
            "tools": [
                ["name": "XcodeRead"],
            ],
        ]))

        let summary = ToolCatalogStartupLogFormatter.summary(from: result)

        #expect(summary == """
        Tools
          DocumentationSearch: unavailable
          Count: 1
          Available:
            - XcodeRead
        """)
    }

    @Test func summaryGroupsAvailableToolsUnderProcessWhenKnown() throws {
        let result = try #require(JSONValue(any: [
            "tools": [
                ["name": "XcodeRead"],
                ["name": "DocumentationSearch"],
            ],
        ]))

        let summary = ToolCatalogStartupLogFormatter.summary(
            from: result,
            process: ToolCatalogStartupLogFormatter.Process(
                appPath: "/Applications/Xcode_27.app",
                processID: 75132
            )
        )

        #expect(summary == """
        Tools
          - /Applications/Xcode_27.app (PID: 75132)
            DocumentationSearch: available
            Count: 2
            Available:
              - DocumentationSearch
              - XcodeRead
        """)
    }
}
