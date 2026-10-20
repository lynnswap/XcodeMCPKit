import Foundation
import Testing
import XcodeMCPCore
@testable import XcodeMCPProxyRuntime

func upstreamEnvironment(from factory: any UpstreamSessionFactory) throws -> [String: String] {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try upstreamEnvironment(fromConfigMirror: configMirror)
}

private func upstreamEnvironment(fromConfigMirror configMirror: Mirror) throws -> [String: String] {
    return try #require(
        configMirror.children.first(where: { $0.label == "environment" })?.value
            as? [String: String],
        "UpstreamProcess.Config should include environment for tests"
    )
}

func upstreamMaxQueuedWriteBytes(from factory: any UpstreamSessionFactory) throws -> Int {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try #require(
        configMirror.children.first(where: { $0.label == "maxQueuedWriteBytes" })?.value as? Int,
        "UpstreamProcess.Config should include maxQueuedWriteBytes for tests"
    )
}


func upstreamCommand(from factory: any UpstreamSessionFactory) throws -> String {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try upstreamCommand(fromConfigMirror: configMirror)
}

private func upstreamCommand(fromConfigMirror configMirror: Mirror) throws -> String {
    return try #require(
        configMirror.children.first(where: { $0.label == "command" })?.value as? String,
        "UpstreamProcess.Config should include command for tests"
    )
}


func upstreamArgs(from factory: any UpstreamSessionFactory) throws -> [String] {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try upstreamArgs(fromConfigMirror: configMirror)
}

private func upstreamArgs(fromConfigMirror configMirror: Mirror) throws -> [String] {
    return try #require(
        configMirror.children.first(where: { $0.label == "args" })?.value as? [String],
        "UpstreamProcess.Config should include args for tests"
    )
}


private func upstreamConfigMirror(from factory: any UpstreamSessionFactory) throws -> Mirror {
    if let factory = factory as? NativeHostSessionFactory {
        return Mirror(reflecting: try factory.processConfiguration(environment: factory.environment))
    }
    let factoryMirror = Mirror(reflecting: factory)
    let config = try #require(
        factoryMirror.children.first(where: { $0.label == "config" })?.value,
        "UpstreamProcess factory should expose a stored config for tests"
    )
    return Mirror(reflecting: config)
}
