import Foundation
import Testing
import XcodeMCPWire

func nativeTestJSON(_ data: Data) throws -> JSONValue {
    try #require(JSONValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])))
}

func nativeTestObject(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else {
        Issue.record("Expected a JSON object, received \(value)")
        throw NativeTestFailure.expectedObject
    }
    return fields
}

func nativeTestField(_ value: JSONValue, _ path: String...) throws -> JSONValue {
    var result = value
    for key in path { result = try #require(nativeTestObject(result)[key]) }
    return result
}

enum NativeTestFailure: Error {
    case expectedObject
}
