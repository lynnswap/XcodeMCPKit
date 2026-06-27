import Foundation

/// Core-owned defaults and Xcode chat client version lookup for the
/// initialize params the proxy presents to mcpbridge. JSON shaping is kept
/// in ProxySession so ProxyCore stays independent of XcodeMCPRuntime.
package enum InitializeHandshakeParams {
    package static func hasExplicitClientVersionOverride(
        initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?
    ) -> Bool {
        initializeParamsOverride?.clientVersion != nil
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
