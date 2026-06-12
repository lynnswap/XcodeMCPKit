import Foundation
import ProxyMCP

/// Resolves the initialize params the proxy presents to mcpbridge:
/// built-in defaults merged with the TOML override, with the clientInfo
/// version auto-detected from Xcode's IDEChat*Version defaults unless the
/// override pins one explicitly.
package enum InitializeHandshakeParams {
    package static func resolved(config: ProxyConfig) -> [String: JSONValue] {
        let override = ProxyFileConfigLoader.loadInitializeParamsOverride(
            configPath: config.configPath,
            logger: ProxyLogging.make("config")
        )
        return resolved(initializeParamsOverride: override)
    }

    package static func resolved(
        initializeParamsOverride: [String: JSONValue]?
    ) -> [String: JSONValue] {
        let mergedParams = ProxyFileConfigLoader.mergeJSONObjects(
            defaultParams(),
            overriding: initializeParamsOverride ?? [:]
        )
        guard hasExplicitClientVersionOverride(initializeParamsOverride: initializeParamsOverride) == false else {
            return mergedParams
        }
        return applyingAutomaticClientVersion(to: mergedParams)
    }

    package static func defaultParams() -> [String: JSONValue] {
        [
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(defaultProxyClientName()),
                "version": .string(defaultProxyClientVersion()),
            ]),
        ]
    }

    package static func hasExplicitClientVersionOverride(
        initializeParamsOverride: [String: JSONValue]?
    ) -> Bool {
        guard case .object(let clientInfo)? = initializeParamsOverride?["clientInfo"] else {
            return false
        }
        return clientInfo["version"] != nil
    }

    package static func applyingAutomaticClientVersion(to params: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(var clientInfo)? = params["clientInfo"],
              case .string(let clientName)? = clientInfo["name"] else {
            return params
        }

        guard let resolvedVersion = xcodeChatClientVersion(for: clientName) else {
            return params
        }

        clientInfo["version"] = .string(resolvedVersion)
        var updated = params
        updated["clientInfo"] = .object(clientInfo)
        return updated
    }

    package static func defaultClientVersion(for clientName: String) -> String {
        xcodeChatClientVersion(for: clientName) ?? defaultProxyClientVersion()
    }

    package static func defaultProxyClientName() -> String {
        "XcodeMCPKit"
    }

    package static func defaultProxyClientVersion() -> String {
        "dev"
    }

    package static func xcodeChatClientVersion(for clientName: String) -> String? {
        let defaults = UserDefaults(suiteName: "com.apple.dt.Xcode")?.dictionaryRepresentation() ?? [:]
        return xcodeChatClientVersion(for: clientName, defaults: defaults)
    }

    package static func xcodeChatClientVersion(for clientName: String, defaults: [String: Any]) -> String? {
        let normalizedName = normalizedChatClientName(clientName)
        guard !normalizedName.isEmpty else { return nil }

        var exactMatches: [(stem: String, version: String)] = []
        var aliasMatches: [(stem: String, version: String)] = []

        for (key, value) in defaults {
            guard key.hasPrefix("IDEChat"), key.hasSuffix("Version") else { continue }
            guard let raw = value as? String, let version = xcodeChatVersionValue(from: raw) else {
                continue
            }

            let stem = String(
                key
                    .dropFirst("IDEChat".count)
                    .dropLast("Version".count)
            )

            let normalizedStem = normalizedChatClientName(stem)
            if normalizedStem == normalizedName {
                exactMatches.append((stem, version))
                continue
            }

            if chatClientAliases(forVersionStem: stem).contains(normalizedName) {
                aliasMatches.append((stem, version))
            }
        }

        let orderedExactMatches = exactMatches.sorted { lhs, rhs in
            lhs.stem.localizedStandardCompare(rhs.stem) == .orderedAscending
        }
        if let match = orderedExactMatches.first {
            return match.version
        }

        let orderedAliasMatches = aliasMatches.sorted { lhs, rhs in
            lhs.stem.localizedStandardCompare(rhs.stem) == .orderedAscending
        }
        return orderedAliasMatches.first?.version
    }

    package static func xcodeChatVersionValue(forDefaultsKey defaultsKey: String) -> String? {
        guard let raw = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: defaultsKey) else {
            return nil
        }
        return xcodeChatVersionValue(from: raw)
    }

    package static func xcodeChatVersionValue(from raw: String) -> String? {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let version = object["version"] as? String,
            !version.isEmpty
        else {
            return nil
        }
        return version
    }

    package static func chatClientAliases(forVersionStem stem: String) -> Set<String> {
        var aliases: Set<String> = []
        let normalizedStem = normalizedChatClientName(stem)
        if !normalizedStem.isEmpty {
            aliases.insert(normalizedStem)
        }

        if stem.hasSuffix("Code") {
            let baseStem = String(stem.dropLast("Code".count))
            let normalizedBaseStem = normalizedChatClientName(baseStem)
            if !normalizedBaseStem.isEmpty {
                aliases.insert(normalizedBaseStem)
            }
        }

        return aliases
    }

    package static func normalizedChatClientName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
}
