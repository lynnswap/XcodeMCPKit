import Foundation
import Testing
import XcodeMCPNativeRuntime
import XcodeMCPWire

@Suite
struct NativeSchemaConverterTests {
    @Test func exposesNewNativeToolsWithoutASeparateToolDefinition() throws {
        let tool = try NativeSchemaConverter.tool(from: Data(Self.richNativeSchema.utf8), workspaceScoped: true)
        #expect(tool.name == "FutureNativeTool")
        #expect(tool.workspaceScoped)
        #expect(try nativeTestField(tool.descriptor, "title") == .string("Future tool"))
        #expect(try nativeTestField(tool.descriptor, "description") == .string("Provided by the selected Xcode."))
        #expect(try nativeTestField(tool.descriptor, "annotations") == .object(["readOnlyHint": .bool(true)]))

        let input = try nativeTestField(tool.descriptor, "inputSchema")
        #expect(try nativeTestField(input, "type") == .string("object"))
        #expect(try nativeTestField(input, "required") == .array([.string("mode"), .string("records")]))
        #expect(try nativeTestField(input, "properties", "mode") == .object([
            "type": .string("string"), "description": .string("Which mode to use."),
            "enum": .array([.string("fast"), .string("complete")]),
        ]))
        #expect(try nativeTestField(input, "properties", "limit") == .object(["type": .string("integer")]))
        #expect(try nativeTestField(input, "properties", "ratio") == .object(["type": .string("number")]))
        #expect(try nativeTestField(input, "properties", "enabled") == .object(["type": .string("boolean")]))
        #expect(try nativeTestField(input, "properties", "extra") == .object(["type": .string("object")]))
        #expect(try nativeTestField(input, "properties", "records") == .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "conversationID": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("tags")]),
            ]),
        ]))
    }

    @Test func hidesOnlyHostManagedInputContextAndAddsAnOptionalWorkspaceSelector() throws {
        let tool = try NativeSchemaConverter.tool(from: Data(Self.richNativeSchema.utf8), workspaceScoped: true)
        let properties = try nativeTestObject(nativeTestField(tool.descriptor, "inputSchema", "properties"))
        #expect(properties["temporaryArtifactsPath"] == nil)
        #expect(properties["conversationID"] == nil)
        #expect(properties["tabIdentifier"] == nil)
        #expect(try nativeTestField(tool.descriptor, "inputSchema", "properties", "workspaceIdentifier", "type") == .string("string"))
        #expect(try nativeTestField(tool.descriptor, "inputSchema", "required") == .array([.string("mode"), .string("records")]))
        // A nested field with the same spelling belongs to the tool's own input.
        #expect(try nativeTestField(tool.descriptor, "inputSchema", "properties", "records", "items", "properties", "conversationID", "type") == .string("string"))
    }

    @Test func preservesOutputFieldsThatShareHostContextNames() throws {
        let tool = try NativeSchemaConverter.tool(from: Data(Self.richNativeSchema.utf8), workspaceScoped: false)
        #expect(try nativeTestField(tool.descriptor, "outputSchema") == .object([
            "type": .string("object"),
            "properties": .object([
                "conversationID": .object(["type": .string("string")]),
                "count": .object(["type": .string("integer"), "enum": .array([.number(.int(1)), .number(.int(2))])]),
            ]),
            "required": .array([.string("conversationID")]),
        ]))
    }

    @Test func leavesUnscopedToolsWithoutAWorkspaceSelector() throws {
        let tool = try NativeSchemaConverter.tool(from: Data(Self.richNativeSchema.utf8), workspaceScoped: false)
        #expect(!tool.workspaceScoped)
        #expect(try nativeTestObject(nativeTestField(tool.descriptor, "inputSchema", "properties"))["workspaceIdentifier"] == nil)
    }

    @Test func allowsToolsWithNoOutputSchemaAndNoArguments() throws {
        let tool = try NativeSchemaConverter.tool(from: Data(#"{"name":"CatalogChangedTool","inputSchema":{"properties":[]}}"#.utf8), workspaceScoped: false)
        #expect(tool.name == "CatalogChangedTool")
        #expect(tool.descriptor == .object([
            "name": .string("CatalogChangedTool"),
            "inputSchema": .object(["type": .string("object"), "properties": .object([:]), "required": .array([])]),
        ]))
    }

    @Test(arguments: [
        #"{"inputSchema":{"properties":[]}}"#,
        #"{"name":"Changed","inputSchema":{"properties":{}}}"#,
        #"{"name":"Changed","inputSchema":{"properties":[{"name":"x","type":{"string":{}}}]}}"#,
        #"{"name":"Changed","inputSchema":{"properties":[{"name":"x","isRequired":false,"type":{"date":{}}}]}}"#,
        #"{"name":"Changed","inputSchema":{"properties":[{"name":"x","isRequired":false,"type":{"array":{}}}]}}"#,
        #"{"name":"Changed","inputSchema":{"properties":[{"name":"x","isRequired":false,"type":{"string":{},"integer":{}}}]}}"#,
        #"{"name":"Changed","inputSchema":{"properties":[]},"outputSchema":{"properties":[{"name":"x","isRequired":false,"type":{"object":{"schema":{}}}}]}}"#,
    ])
    func reportsUnsupportedNativeContractsInsteadOfAdvertisingAnIncompleteTool(raw: String) {
        #expect(throws: NativeRuntimeError.self) {
            try NativeSchemaConverter.tool(from: Data(raw.utf8), workspaceScoped: false)
        }
    }

    private static let richNativeSchema = #"""
    {
      "name":"FutureNativeTool","title":"Future tool","description":"Provided by the selected Xcode.",
      "annotations":{"readOnlyHint":true},
      "inputSchema":{"properties":[
        {"name":"mode","isRequired":true,"type":{"string":{}},"description":"Which mode to use.","knownValues":["fast","complete"]},
        {"name":"limit","isRequired":false,"type":{"integer":{}},"knownValues":[]},
        {"name":"ratio","isRequired":false,"type":{"number":{}}},
        {"name":"enabled","isRequired":false,"type":{"boolean":{}}},
        {"name":"extra","isRequired":false,"type":{"object":{}}},
        {"name":"records","isRequired":true,"type":{"array":{"itemType":{"object":{"schema":{"properties":[
          {"name":"tags","isRequired":true,"type":{"array":{"itemType":{"string":{}}}}},
          {"name":"conversationID","isRequired":false,"type":{"string":{}}}
        ]}}}}}},
        {"name":"temporaryArtifactsPath","isRequired":true,"type":{"string":{}}},
        {"name":"conversationID","isRequired":true,"type":{"string":{}}},
        {"name":"tabIdentifier","isRequired":true,"type":{"string":{}}}
      ]},
      "outputSchema":{"properties":[
        {"name":"conversationID","isRequired":true,"type":{"string":{}}},
        {"name":"count","isRequired":false,"type":{"integer":{}},"knownValues":[1,2]}
      ]}
    }
    """#
}
