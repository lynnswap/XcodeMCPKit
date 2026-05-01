import Foundation
import Testing

struct ArchitectureTests {
    @Test func requiredSourceDirectoriesExist() throws {
        let packageRoot = try packageRootURL()
        for directory in requiredSourceDirectories {
            let url = packageRoot.appendingPathComponent(directory, isDirectory: true)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            #expect(values?.isDirectory == true)
        }
    }

    @Test func sourceTargetsDoNotImportForbiddenHigherLevelModules() throws {
        let packageRoot = try packageRootURL()
        var violations: [String] = []

        for rule in forbiddenImportRules {
            let sourceURL = packageRoot.appendingPathComponent(rule.sourceDirectory, isDirectory: true)
            for fileURL in swiftFiles(under: sourceURL) {
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                {
                    let normalizedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let importedModule = importedModule(from: normalizedLine),
                          rule.forbiddenModules.contains(importedModule)
                    else {
                        continue
                    }
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: packageRoot.path + "/",
                        with: ""
                    )
                    violations.append("\(relativePath):\(offset + 1): import \(importedModule)")
                }
            }
        }

        if !violations.isEmpty {
            Issue.record("Forbidden imports detected:\n\(violations.sorted().joined(separator: "\n"))")
        }
        #expect(violations.isEmpty)
    }
}

private let requiredSourceDirectories = [
    "Sources/ProxyCore",
    "Sources/ProxyMCP",
    "Sources/ProxySession",
    "Sources/ProxyXcodeSupport",
    "Sources/ProxyXcodeFeatures",
    "Sources/ProxyHTTPGateway",
    "Sources/ProxyStdioTransport",
    "Sources/XcodeMCPProxy",
    "Sources/ProxyCLI",
]

private struct ForbiddenImportRule {
    let sourceDirectory: String
    let forbiddenModules: Set<String>
}

private let forbiddenImportRules = [
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCore",
        forbiddenModules: [
            "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy", "ProxyCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyMCP",
        forbiddenModules: [
            "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy", "ProxyCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxySession",
        forbiddenModules: [
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy", "ProxyCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyXcodeSupport",
        forbiddenModules: [
            "ProxyMCP", "ProxySession", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy", "ProxyCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyXcodeFeatures",
        forbiddenModules: ["ProxySession", "ProxyHTTPGateway", "ProxyStdioTransport", "XcodeMCPProxy", "ProxyCLI"]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyHTTPGateway",
        forbiddenModules: ["ProxyStdioTransport", "XcodeMCPProxy", "ProxyCLI"]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyStdioTransport",
        forbiddenModules: [
            "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "XcodeMCPProxy", "ProxyCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCLI",
        forbiddenModules: [
            "ProxyCore", "ProxyMCP", "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures",
            "ProxyHTTPGateway", "ProxyStdioTransport",
        ]
    ),
]

private enum ArchitectureTestError: Error {
    case packageRootNotFound
}

private func packageRootURL() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()

    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }

    throw ArchitectureTestError.packageRootNotFound
}

private func swiftFiles(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        return []
    }

    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        files.append(url)
    }
    return files
}

private func importedModule(from line: String) -> String? {
    guard line.hasPrefix("import ") else { return nil }
    let module = line.dropFirst("import ".count)
    guard module.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
        return nil
    }
    return String(module)
}
