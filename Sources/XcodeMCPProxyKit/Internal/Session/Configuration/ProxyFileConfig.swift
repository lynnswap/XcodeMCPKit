import Foundation
import TOMLDecoder

extension ProxyConfig.File {
    struct LoadedConfiguration: Sendable {
        let disabledToolNames: Set<String>
        let initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?
    }

    enum LoadError: Error, CustomStringConvertible, Sendable {
        case readFailed(URL, String)
        case decodeFailed(URL, String)

        var description: String {
            switch self {
            case .readFailed(let url, let detail):
                return "Failed to read proxy config at \(url.path): \(detail)"
            case .decodeFailed(let url, let detail):
                return "Failed to decode proxy config at \(url.path): \(detail)"
            }
        }
    }

    enum Number: Sendable, Equatable {
        case int(Int64)
        case double(Double)
    }

    enum Value: Sendable, Equatable {
        case object([String: ProxyConfig.File.Value])
        case array([ProxyConfig.File.Value])
        case string(String)
        case number(ProxyConfig.File.Number)
        case bool(Bool)
        case null

        init?(any value: Any) {
            switch value {
            case is NSNull:
                self = .null
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
                var array: [ProxyConfig.File.Value] = []
                array.reserveCapacity(value.count)
                for item in value {
                    guard let mapped = ProxyConfig.File.Value(any: item) else { return nil }
                    array.append(mapped)
                }
                self = .array(array)
            case let value as [String: Any]:
                var object: [String: ProxyConfig.File.Value] = [:]
                object.reserveCapacity(value.count)
                for (key, item) in value {
                    guard let mapped = ProxyConfig.File.Value(any: item) else { return nil }
                    object[key] = mapped
                }
                self = .object(object)
            default:
                return nil
            }
        }
    }

    struct InitializeHandshakeOverride: Sendable, Equatable {
        let protocolVersion: String?
        let clientName: String?
        let clientVersion: String?
        let capabilities: [String: ProxyConfig.File.Value]?

        var isEmpty: Bool {
            protocolVersion == nil
                && clientName == nil
                && clientVersion == nil
                && capabilities == nil
        }

        init(
            protocolVersion: String? = nil,
            clientName: String? = nil,
            clientVersion: String? = nil,
            capabilities: [String: ProxyConfig.File.Value]? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
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
        ) throws -> [String: ProxyConfig.File.Value] {
            let object = try Dictionary(table)
            var values: [String: ProxyConfig.File.Value] = [:]
            values.reserveCapacity(object.count)
            for (key, value) in object {
                guard let mapped = ProxyConfig.File.Value(any: value) else {
                    throw ProxyFileConfigError.nonJSONCompatibleCapabilities
                }
                values[key] = mapped
            }
            return values
        }

        func merging(
            overriding override: ProxyConfig.File.InitializeHandshakeOverride
        ) -> ProxyConfig.File.InitializeHandshakeOverride {
            ProxyConfig.File.InitializeHandshakeOverride(
                protocolVersion: override.protocolVersion ?? protocolVersion,
                clientName: override.clientName ?? clientName,
                clientVersion: override.clientVersion ?? clientVersion,
                capabilities: override.capabilities ?? capabilities
            )
        }
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

extension ProxyConfig.File {
    enum Loader {
        static func loadStrict(configURL: URL) throws -> ProxyConfig.File.LoadedConfiguration {
            let data: Data
            do {
                data = try Data(contentsOf: configURL)
            } catch {
                throw ProxyConfig.File.LoadError.readFailed(
                    configURL,
                    String(describing: error)
                )
            }

            let config: ProxyFileConfig
            do {
                config = try TOMLDecoder(isLenient: false).decode(ProxyFileConfig.self, from: data)
            } catch {
                throw ProxyConfig.File.LoadError.decodeFailed(
                    configURL,
                    String(describing: error)
                )
            }

            let disabledToolNames: Set<String>
            switch config.tools {
            case .missing:
                disabledToolNames = []
            case .invalid(let detail):
                throw ProxyConfig.File.LoadError.decodeFailed(configURL, "tools: \(detail)")
            case .decoded(let tools):
                disabledToolNames = ProxyConfig.normalizedToolNames(tools.disabled ?? [])
            }

            let initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?
            switch config.upstreamHandshake {
            case .missing:
                initializeParamsOverride = nil
            case .invalid(let detail):
                throw ProxyConfig.File.LoadError.decodeFailed(
                    configURL,
                    "upstream_handshake: \(detail)"
                )
            case .decoded(let fileConfig):
                do {
                    let value = try ProxyConfig.File.InitializeHandshakeOverride(
                        fileConfig: fileConfig
                    )
                    initializeParamsOverride = value.isEmpty ? nil : value
                } catch {
                    throw ProxyConfig.File.LoadError.decodeFailed(
                        configURL,
                        String(describing: error)
                    )
                }
            }

            return ProxyConfig.File.LoadedConfiguration(
                disabledToolNames: disabledToolNames,
                initializeParamsOverride: initializeParamsOverride
            )
        }

    }
}
