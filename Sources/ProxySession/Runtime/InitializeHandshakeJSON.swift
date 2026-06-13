import Foundation
import ProxyCore
import ProxyMCP

package enum InitializeHandshakeJSON {
    package static func resolved(
        initializeParamsOverride: ProxyInitializeHandshakeOverride?
    ) -> [String: JSONValue] {
        let mergedParams = mergeJSONObjects(
            defaultParams(),
            overriding: jsonObject(from: initializeParamsOverride) ?? [:]
        )
        guard InitializeHandshakeParams.hasExplicitClientVersionOverride(
            initializeParamsOverride: initializeParamsOverride
        ) == false else {
            return mergedParams
        }
        return applyingAutomaticClientVersion(to: mergedParams)
    }

    package static func defaultParams() -> [String: JSONValue] {
        [
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(InitializeHandshakeParams.defaultProxyClientName()),
                "version": .string(InitializeHandshakeParams.defaultProxyClientVersion()),
            ]),
        ]
    }

    private static func jsonObject(
        from override: ProxyInitializeHandshakeOverride?
    ) -> [String: JSONValue]? {
        guard let override else { return nil }
        var params: [String: JSONValue] = [:]
        if let protocolVersion = override.protocolVersion {
            params["protocolVersion"] = .string(protocolVersion)
        }

        var clientInfo: [String: JSONValue] = [:]
        if let clientName = override.clientName {
            clientInfo["name"] = .string(clientName)
        }
        if let clientVersion = override.clientVersion {
            clientInfo["version"] = .string(clientVersion)
        }
        if clientInfo.isEmpty == false {
            params["clientInfo"] = .object(clientInfo)
        }

        if let capabilities = override.capabilities {
            params["capabilities"] = .object(capabilities.mapValues(jsonValue(from:)))
        }

        return params.isEmpty ? nil : params
    }

    private static func jsonValue(from value: ProxyConfigValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.mapValues(jsonValue(from:)))
        case .array(let array):
            return .array(array.map(jsonValue(from:)))
        case .string(let string):
            return .string(string)
        case .number(.int(let number)):
            return .number(.int(number))
        case .number(.double(let number)):
            return .number(.double(number))
        case .bool(let bool):
            return .bool(bool)
        }
    }

    private static func applyingAutomaticClientVersion(
        to params: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard case .object(var clientInfo)? = params["clientInfo"],
              case .string(let clientName)? = clientInfo["name"] else {
            return params
        }

        guard let resolvedVersion = InitializeHandshakeParams.xcodeChatClientVersion(
            for: clientName
        ) else {
            return params
        }

        clientInfo["version"] = .string(resolvedVersion)
        var updated = params
        updated["clientInfo"] = .object(clientInfo)
        return updated
    }

    private static func mergeJSONObjects(
        _ base: [String: JSONValue],
        overriding override: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = base
        for (key, value) in override {
            if case .object(let overrideObject) = value,
               case .object(let baseObject)? = merged[key]
            {
                merged[key] = .object(
                    mergeJSONObjects(baseObject, overriding: overrideObject)
                )
            } else {
                merged[key] = value
            }
        }
        return merged
    }
}
