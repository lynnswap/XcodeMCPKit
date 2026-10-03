import Foundation

package struct NativeGUIMessageCapabilities: Sendable {
    package let supportsToolCancellation: Bool

    @MainActor package static func loaded(from binary: URL, initializingWith message: Data) async throws -> Self {
        let abi = NativeABI()
        guard let type = try await abi.typeMetadata(named: "IDEIntelligenceMessaging.BridgeToToolService.OneWayMessage", in: binary) as? any Decodable.Type else {
            throw NativeRuntimeError.unsupportedContract("Native GUI one-way message type is unavailable")
        }
        return try Self(oneWayType: type, initializingWith: message)
    }

    package init(oneWayType: any Decodable.Type, initializingWith message: Data) throws {
        try Self.decode(oneWayType, data: message)
        do {
            try Self.decode(oneWayType, data: Data(#"{"cancelToolCall":{"name":"capability-probe","progressToken":"00000000-0000-0000-0000-000000000000"}}"#.utf8))
            supportsToolCancellation = true
        } catch is DecodingError {
            // A message rejected by the loaded enum cannot safely be sent to its peer.
            supportsToolCancellation = false
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws {
        _ = try JSONDecoder().decode(type, from: data)
    }
}
