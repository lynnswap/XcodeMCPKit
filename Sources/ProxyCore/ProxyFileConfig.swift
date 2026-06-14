import Foundation
import Logging
import TOMLDecoder

package enum ProxyConfigNumber: Sendable, Equatable {
    case int(Int64)
    case double(Double)
}

package enum ProxyConfigValue: Sendable, Equatable {
    case object([String: ProxyConfigValue])
    case array([ProxyConfigValue])
    case string(String)
    case number(ProxyConfigNumber)
    case bool(Bool)

    package init?(any value: Any) {
        switch value {
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(.int(Int64(value)))
        case let value as Int64:
            self = .number(.int(value))
        case let value as Double where value.isFinite:
            self = .number(.double(value))
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var array: [ProxyConfigValue] = []
            array.reserveCapacity(value.count)
            for item in value {
                guard let mapped = ProxyConfigValue(any: item) else { return nil }
                array.append(mapped)
            }
            self = .array(array)
        case let value as [String: Any]:
            var object: [String: ProxyConfigValue] = [:]
            object.reserveCapacity(value.count)
            for (key, item) in value {
                guard let mapped = ProxyConfigValue(any: item) else { return nil }
                object[key] = mapped
            }
            self = .object(object)
        default:
            return nil
        }
    }
}

package struct ProxyInitializeHandshakeOverride: Sendable, Equatable {
    package let protocolVersion: String?
    package let clientName: String?
    package let clientVersion: String?
    package let capabilities: [String: ProxyConfigValue]?

    package var isEmpty: Bool {
        protocolVersion == nil
            && clientName == nil
            && clientVersion == nil
            && capabilities == nil
    }

    fileprivate init(fileConfig: ProxyInitializeHandshakeFileConfig) throws {
        protocolVersion = fileConfig.protocolVersion
        clientName = fileConfig.clientName
        clientVersion = fileConfig.clientVersion
        if let capabilities = fileConfig.capabilities {
            self.capabilities = try Self.configValues(from: capabilities)
        } else {
            self.capabilities = nil
        }
    }

    private static func configValues(
        from table: TOMLTable
    ) throws -> [String: ProxyConfigValue] {
        let object = try Dictionary(table)
        var values: [String: ProxyConfigValue] = [:]
        values.reserveCapacity(object.count)
        for (key, value) in object {
            guard let mapped = ProxyConfigValue(any: value) else {
                throw ProxyFileConfigError.nonJSONCompatibleCapabilities
            }
            values[key] = mapped
        }
        return values
    }
}

private struct ProxyInitializeHandshakeFileConfig: Decodable, Sendable {
    let protocolVersion: String?
    let clientName: String?
    let clientVersion: String?
    let capabilities: TOMLTable?
}

private enum ProxyFileConfigError: Error {
    case nonJSONCompatibleCapabilities
}

private struct ProxyFileConfig: Decodable, Sendable {
    let upstreamHandshake: DecodedSection<ProxyInitializeHandshakeFileConfig>
    let tools: DecodedSection<ProxyToolsConfig>

    private enum CodingKeys: String, CodingKey {
        case upstreamHandshake = "upstream_handshake"
        case tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upstreamHandshake = Self.decodeSection(
            ProxyInitializeHandshakeFileConfig.self,
            forKey: .upstreamHandshake,
            in: container
        )
        tools = Self.decodeSection(ProxyToolsConfig.self, forKey: .tools, in: container)
    }

    private static func decodeSection<Value: Decodable & Sendable>(
        _ type: Value.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodedSection<Value> {
        guard container.contains(key) else { return .missing }
        do {
            return .decoded(try container.decode(type, forKey: key))
        } catch {
            return .invalid(String(describing: error))
        }
    }
}

private enum DecodedSection<Value: Sendable>: Sendable {
    case missing
    case decoded(Value)
    case invalid(String)
}

private struct ProxyToolsConfig: Decodable, Sendable, Equatable {
    let disabled: [String]?
}

package enum ProxyFileConfigLoader {
    package static func loadInitializeParamsOverride(
        configPath: String?,
        logger: Logger
    ) -> ProxyInitializeHandshakeOverride? {
        guard let loaded = loadConfig(
            configPath: configPath,
            logger: logger,
            readFailureMessage: "Failed to read proxy config; using built-in initialize params",
            decodeFailureMessage: "Failed to decode proxy config; using built-in initialize params"
        ) else {
            return nil
        }
        let expandedPath = loaded.path
        switch loaded.config.upstreamHandshake {
        case .missing:
            logger.warning(
                "Proxy config does not define upstream_handshake; using built-in initialize params",
                metadata: ["path": .string(expandedPath)]
            )
            return nil
        case .invalid(let error):
            logger.warning(
                "Proxy config upstream_handshake is invalid; using built-in initialize params",
                metadata: [
                    "path": .string(expandedPath),
                    "error": .string(error),
                ]
            )
            return nil
        case .decoded(let fileConfig):
            let override: ProxyInitializeHandshakeOverride
            do {
                override = try ProxyInitializeHandshakeOverride(fileConfig: fileConfig)
            } catch {
                logger.warning(
                    "Proxy config capabilities are not JSON-compatible; using built-in initialize params",
                    metadata: [
                        "path": .string(expandedPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }
            return override.isEmpty ? nil : override
        }
    }

    package static func loadDisabledToolNames(
        configPath: String?,
        logger: Logger
    ) -> Set<String> {
        guard let loaded = loadConfig(
            configPath: configPath,
            logger: logger,
            readFailureMessage: "Failed to read proxy config; ignoring disabled tools",
            decodeFailureMessage: "Failed to decode proxy config; ignoring disabled tools"
        ) else {
            return []
        }
        let expandedPath = loaded.path
        switch loaded.config.tools {
        case .missing:
            return []
        case .invalid(let error):
            logger.warning(
                "Proxy config tools is invalid; ignoring disabled tools",
                metadata: [
                    "path": .string(expandedPath),
                    "error": .string(error),
                ]
            )
            return []
        case .decoded(let tools):
            guard let disabled = tools.disabled else {
                return []
            }
            var disabledToolNames = Set<String>()
            for rawName in disabled {
                let normalizedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedName.isEmpty == false else {
                    continue
                }
                disabledToolNames.insert(normalizedName)
            }
            return disabledToolNames
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func loadConfig(
        configPath: String?,
        logger: Logger,
        readFailureMessage: String,
        decodeFailureMessage: String
    ) -> (path: String, config: ProxyFileConfig)? {
        guard let rawPath = nonEmpty(configPath) else { return nil }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning(
                "\(readFailureMessage)",
                metadata: [
                    "path": .string(expandedPath),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
        }

        let config: ProxyFileConfig
        do {
            config = try TOMLDecoder(isLenient: false).decode(ProxyFileConfig.self, from: data)
        } catch {
            logger.warning(
                "\(decodeFailureMessage)",
                metadata: [
                    "path": .string(expandedPath),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
        }

        return (expandedPath, config)
    }
}
