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
    "Sources/ProxyBuildInfo",
    "Sources/ProxyMCPContract",
    "Sources/ProxyCore",
    "Sources/ProxyMCP",
    "Sources/ProxySessionControlPlane",
    "Sources/ProxySessionUpstream",
    "Sources/ProxySession",
    "Sources/ProxyXcodeSupport",
    "Sources/ProxyXcodeFeatures",
    "Sources/ProxyHTTPGateway",
    "Sources/ProxyStdioTransport",
    "Sources/XcodeMCPProxy",
    "Sources/ProxyCLI/Common",
    "Sources/ProxyCLI/Adapter",
    "Sources/ProxyCLI/Server",
    "Sources/ProxyCLI/Install",
]

private struct ForbiddenImportRule {
    let sourceDirectory: String
    let forbiddenModules: Set<String>
}

private let forbiddenImportRules = [
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyMCPContract",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxyCore",
            "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCore",
        forbiddenModules: [
            "ProxyBuildInfo",
            "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyMCP",
        forbiddenModules: [
            "ProxyBuildInfo",
            "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxySessionControlPlane",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
            "AppKit", "ApplicationServices",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxySessionUpstream",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxySessionControlPlane", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
            "AppKit", "ApplicationServices",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxySession",
        forbiddenModules: [
            "ProxyBuildInfo",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
            "AppKit", "ApplicationServices",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyXcodeSupport",
        forbiddenModules: [
            "ProxyBuildInfo",
            "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyXcodeFeatures",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyHTTPGateway", "ProxyStdioTransport",
            "XcodeMCPProxy", "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyHTTPGateway",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxySessionUpstream", "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyStdioTransport",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxySessionControlPlane", "ProxySessionUpstream",
            "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures",
            "ProxyHTTPGateway", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyBuildInfo",
        forbiddenModules: [
            "ProxyCore", "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream",
            "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures",
            "ProxyHTTPGateway", "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/XcodeMCPProxy",
        forbiddenModules: ["ProxyCLICommon", "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI"]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCLI/Common",
        forbiddenModules: [
            "ProxyBuildInfo", "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream",
            "ProxySession", "ProxyXcodeSupport", "ProxyXcodeFeatures",
            "ProxyHTTPGateway", "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyAdapterCLI", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCLI/Adapter",
        forbiddenModules: [
            "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures",
            "ProxyHTTPGateway", "XcodeMCPProxy", "ProxyServerCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCLI/Server",
        forbiddenModules: [
            "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures", "ProxyHTTPGateway",
            "ProxyStdioTransport", "ProxyAdapterCLI", "ProxyInstallCLI",
        ]
    ),
    ForbiddenImportRule(
        sourceDirectory: "Sources/ProxyCLI/Install",
        forbiddenModules: [
            "ProxyMCP", "ProxySessionControlPlane", "ProxySessionUpstream", "ProxySession",
            "ProxyXcodeSupport", "ProxyXcodeFeatures",
            "ProxyHTTPGateway", "ProxyStdioTransport", "XcodeMCPProxy",
            "ProxyAdapterCLI", "ProxyServerCLI",
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
    // @_exported / @testable re-exports count as imports too; they must not
    // become a side door around the layering rules.
    var line = line
    while line.hasPrefix("@") {
        guard let spaceIndex = line.firstIndex(of: " ") else { return nil }
        line = String(line[line.index(after: spaceIndex)...])
    }
    guard line.hasPrefix("import ") else { return nil }
    let module = line.dropFirst("import ".count)
    guard module.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
        return nil
    }
    return String(module)
}
