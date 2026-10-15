import CryptoKit
import Foundation
import XcodeMCPKit

struct PreviewFixtureDefinition: Codable, Sendable {
    let id: String
    let directory: String
    let project: String
    let sourceVariant: String?
    let sourceDestination: String?
    let cases: [PreviewVerificationCase]

    static func load(in repository: URL) throws -> [Self] {
        let url = repository.appendingPathComponent("Fixtures/PreviewVerifier/fixtures.json")
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }
}

struct PreviewVerificationCase: Codable, Equatable, Sendable {
    let id: String
    let sourceFile: String
    let navigatorPath: String
    let scheme: String
    let index: Int
    let arguments: [String: MCPJSONValue]
}

struct PreparedPreviewFixture: Codable, Sendable {
    let definition: PreviewFixtureDefinition
    let files: [String: String]

    static func load(at root: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
    }

    static func prepare(definition: PreviewFixtureDefinition, repository: URL, output: URL,
                        deviceName: String?, buildSettings: URL?) throws -> Self {
        let fileManager = FileManager.default
        let fixtures = repository.appendingPathComponent("Fixtures/PreviewVerifier")
        let original = fixtures.appendingPathComponent(definition.directory).standardizedFileURL
        let project = output.appendingPathComponent("Project", isDirectory: true)
        try createPreviewOutput(output)
        try fileManager.copyItem(at: original, to: project)
        if let variant = definition.sourceVariant, let destination = definition.sourceDestination {
            var source = try String(contentsOf: fixtures.appendingPathComponent(variant), encoding: .utf8)
            if source.contains("__PREVIEW_DEVICE_NAME__") {
                guard let deviceName else {
                    throw VerifierFailure("\(definition.id) requires --device-name for its source previewDevice")
                }
                source = source.replacingOccurrences(of: "__PREVIEW_DEVICE_NAME__", with: String(reflecting: deviceName))
            }
            try source.write(to: project.appendingPathComponent(destination), atomically: true, encoding: .utf8)
        }
        if let buildSettings {
            let settings = try JSONDecoder().decode(PreviewBuildSettings.self, from: Data(contentsOf: buildSettings))
            try applyPreviewBuildSettings(settings, project: project.appendingPathComponent(definition.project))
        }
        let prepared = PreparedPreviewFixture(definition: definition, files: try previewFileDigests(in: project))
        try writePreviewJSON(prepared, to: output.appendingPathComponent("fixture.json"))
        return prepared
    }
}

// Target name -> configuration name -> setting name -> value. Values stay in the owned copy.
typealias PreviewBuildSettings = [String: [String: [String: String]]]

func applyPreviewBuildSettings(_ settings: PreviewBuildSettings, project: URL) throws {
    let url = project.appendingPathComponent("project.pbxproj")
    guard var plist = try unsafe PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
          var objects = plist["objects"] as? [String: [String: Any]] else {
        throw VerifierFailure("Cannot read project objects in \(url.path)")
    }
    for (targetName, configurations) in settings {
        guard let target = objects.values.first(where: { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == targetName }),
              let listID = target["buildConfigurationList"] as? String,
              let configurationIDs = objects[listID]?["buildConfigurations"] as? [String] else {
            throw VerifierFailure("No build configurations for target \(targetName)")
        }
        for (configurationName, values) in configurations {
            guard let identifier = configurationIDs.first(where: { objects[$0]?["name"] as? String == configurationName }),
                  var configuration = objects[identifier] else {
                throw VerifierFailure("No \(configurationName) configuration for target \(targetName)")
            }
            var buildSettings = configuration["buildSettings"] as? [String: Any] ?? [:]
            for (key, value) in values { buildSettings[key] = value }
            configuration["buildSettings"] = buildSettings
            objects[identifier] = configuration
        }
    }
    plist["objects"] = objects
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
}

func createPreviewOutput(_ output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw VerifierFailure("Output already exists: \(output.path). Choose a new directory to preserve previous results.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
}

func previewFileDigests(in root: URL) throws -> [String: String] {
    let ignored: Set<String> = ["xcuserdata", "project.xcworkspace", "DerivedData", ".build", ".DS_Store"]
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
    var result: [String: String] = [:]
    for file in files where !ignored.contains(file.lastPathComponent) {
        let properties = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if properties.isDirectory == true {
            for (path, digest) in try previewFileDigests(in: file) { result[file.lastPathComponent + "/" + path] = digest }
        } else if properties.isRegularFile == true {
            result[file.lastPathComponent] = try previewSHA256(file)
        }
    }
    return result
}

func previewSHA256(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file)).map {
        let byte = String($0, radix: 16)
        return byte.count == 1 ? "0" + byte : byte
    }.joined()
}

func writePreviewJSON(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}
