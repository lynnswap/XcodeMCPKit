import Foundation

/// Reads the input side of one completed native build; generated descriptions and depfiles are discovery data.
struct NativePreviewBuildInputs {
    struct Inputs: Equatable {
        let files: Set<URL>
        let missing: Set<URL>
    }

    enum ResponseFileSyntax: Equatable { case llvmGNU, swiftDriver }

    struct CompilerCommand {
        let arguments: [String]
        let workingDirectory: URL?
        var responseFileSyntax: ResponseFileSyntax? = nil
    }

    private struct Manifest: Decodable {
        let commands: [String: Command]
    }

    private struct Command: Decodable {
        let tool: String
        let inputs: [String]?
        let outputs: [String]
        let args: [String]?
        let deps: Paths?
        let dependencyStyle: String?
        let workingDirectory: String?

        enum CodingKeys: String, CodingKey {
            case tool, inputs, outputs, args, deps
            case dependencyStyle = "deps-style"
            case workingDirectory = "working-directory"
        }
    }

    private struct Paths: Decodable {
        let values: [String]
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { values = [value] }
            else { values = try container.decode([String].self) }
        }
    }

    private enum Unsupported: Error { case inputDescription }

    static func files(manifest manifestURL: URL, compilerCommands: [CompilerCommand] = [],
                      immutableRoots: [URL] = [], read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> Inputs? {
        do {
            var descriptions: [URL: Data] = [:]
            func readDescription(_ url: URL) throws -> Data {
                if let data = descriptions[url] { return data }
                let data = try read(url)
                descriptions[url] = data
                return data
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: readDescription(manifestURL))
            guard !manifest.commands.isEmpty else { throw Unsupported.inputDescription }
            let produced = try Set(manifest.commands.values.flatMap(\.outputs).compactMap { path in
                try absoluteNode(path)
            })
            let swiftCommands = manifest.commands.values.filter {
                $0.tool == "swift-driver-compilation" || $0.tool == "swift-driver-compilation-requirement"
            }
            let swiftObjectOutputs = try Set(swiftCommands.flatMap(\.outputs).compactMap { path -> URL? in
                guard let url = try absoluteNode(path), url.pathExtension == "o" else { return nil }
                return url
            })
            var parsedSwiftMaps: Set<URL> = []
            var inputs: Set<URL> = []
            var missing: Set<URL> = []
            var dependencyFiles: Set<URL> = []
            var responseFiles: Set<URL> = []
            for command in manifest.commands.values {
                for path in command.inputs ?? [] {
                    if let url = try absoluteNode(path) { inputs.insert(url) }
                }
                let directory = try command.workingDirectory.map {
                    URL(filePath: try absolutePath($0).path, directoryHint: .isDirectory)
                }
                if let paths = command.deps?.values {
                    guard !paths.isEmpty else { throw Unsupported.inputDescription }
                    for path in paths {
                        let url = try pathURL(path, relativeTo: directory)
                        dependencyFiles.insert(url)
                        let data = try readDescription(url)
                        switch (command.dependencyStyle, command.tool) {
                        case ("makefile", _):
                            inputs.formUnion(try makefileInputs(data, relativeTo: directory))
                        case ("dependency-info", _), (nil, "linker"), (nil, "embed-swift-stdlib"):
                            let dependencies = try dependencyInfoInputs(data, relativeTo: directory)
                            inputs.formUnion(dependencies.files)
                            missing.formUnion(dependencies.missing)
                        default: throw Unsupported.inputDescription
                        }
                    }
                }
                if command.tool == "swift-driver-compilation" || command.tool == "swift-driver-compilation-requirement" {
                    let objectOutputs = try Set(command.outputs.compactMap { path -> URL? in
                        guard let url = try absoluteNode(path), url.pathExtension == "o" else { return nil }
                        return url
                    })
                    var candidates: [(URL, [String: [String: String]])] = []
                    for path in command.inputs ?? [] {
                        guard let url = try absoluteNode(path), url.pathExtension == "json" else { continue }
                        let data = try readDescription(url)
                        guard let map = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { continue }
                        let mappedObjects = try Set(map.values.compactMap { entry in
                            try entry["object"].map { try pathURL($0, relativeTo: directory) }
                        })
                        if !mappedObjects.isEmpty, mappedObjects.isSubset(of: swiftObjectOutputs),
                           objectOutputs.isSubset(of: mappedObjects) { candidates.append((url, map)) }
                    }
                    guard candidates.count == 1, let (mapURL, map) = candidates.first else {
                        throw Unsupported.inputDescription
                    }
                    if parsedSwiftMaps.insert(mapURL).inserted {
                        dependencyFiles.insert(mapURL)
                        let mappedObjects = try Set(map.values.compactMap { entry in
                            try entry["object"].map { try pathURL($0, relativeTo: directory) }
                        })
                        let moduleOutputs = try Set(swiftCommands.filter { sibling in
                            try (sibling.inputs ?? []).contains { try absoluteNode($0) == mapURL }
                        }.flatMap(\.outputs).compactMap { path -> URL? in
                            guard let url = try absoluteNode(path), url.pathExtension == "swiftmodule" else { return nil }
                            return url
                        })
                        var coveredOutputs: Set<URL> = []
                        func loadDependencies(_ path: String) throws {
                            let url = try pathURL(path, relativeTo: directory)
                            dependencyFiles.insert(url)
                            let rule = try makefileDescription(readDescription(url), relativeTo: directory)
                            inputs.formUnion(rule.inputs)
                            coveredOutputs.formUnion(try rule.targets.map { try pathURL($0, relativeTo: directory) })
                        }
                        for entry in map.values {
                            if let path = entry["dependencies"] { try loadDependencies(path) }
                        }
                        guard mappedObjects.isSubset(of: coveredOutputs) else { throw Unsupported.inputDescription }
                        // WMO can emit modules in the primary job; its map still lists an unused split-job depfile.
                        if moduleOutputs.isEmpty || !moduleOutputs.isSubset(of: coveredOutputs) {
                            for entry in map.values {
                                if let path = entry["emit-module-dependencies"] { try loadDependencies(path) }
                            }
                        }
                        guard moduleOutputs.isSubset(of: coveredOutputs) else { throw Unsupported.inputDescription }
                    }
                }
                if let arguments = command.args, arguments.contains("-c") {
                    try collectResponseFiles(arguments, relativeTo: directory, read: readDescription, into: &responseFiles)
                }
            }
            for command in compilerCommands {
                try collectResponseFiles(command.arguments, relativeTo: command.workingDirectory,
                    syntax: command.responseFileSyntax, read: readDescription, into: &responseFiles)
            }
            inputs.formUnion(responseFiles)
            let discoveryFiles = dependencyFiles.union([manifestURL.standardizedFileURL])
            func tracked(_ files: Set<URL>) -> Set<URL> {
                files.subtracting(produced).subtracting(discoveryFiles).filter { input in
                    !immutableRoots.contains { root in
                        input.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
                            && input.resolvingSymlinksInPath().pathComponents.starts(
                                with: root.resolvingSymlinksInPath().pathComponents)
                    }
                }
            }
            return Inputs(files: tracked(inputs), missing: tracked(missing.subtracting(inputs)))
        } catch {
            // Failure to certify inputs disables reuse; the completed native build remains usable.
            return nil
        }
    }

    /// LLVM/GCC dependency rules, including escaped spaces, punctuation, dollars, continuations and phony rules.
    static func makefileInputs(_ data: Data, relativeTo directory: URL?) throws -> Set<URL> {
        try makefileDescription(data, relativeTo: directory).inputs
    }

    private static func makefileDescription(_ data: Data, relativeTo directory: URL?) throws -> (inputs: Set<URL>, targets: Set<String>) {
        guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw Unsupported.inputDescription
        }
        let characters = Array(text)
        var index = 0
        var token = ""
        var targets: [String] = []
        var dependencies: [String] = []
        var inDependencies = false
        var ruleCount = 0
        var result: Set<URL> = []
        var outputTargets: Set<String> = []
        func flush() {
            guard !token.isEmpty else { return }
            if inDependencies { dependencies.append(token) }
            else { targets.append(token) }
            token = ""
        }
        func finishRule() throws {
            flush()
            if targets.isEmpty, dependencies.isEmpty, !inDependencies { return }
            guard inDependencies, !targets.isEmpty else { throw Unsupported.inputDescription }
            for dependency in dependencies { result.insert(try pathURL(dependency, relativeTo: directory)) }
            outputTargets.formUnion(targets)
            targets = []
            dependencies = []
            inDependencies = false
            ruleCount += 1
        }
        while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "\\":
                guard index < characters.count else { throw Unsupported.inputDescription }
                let next = characters[index]
                index += 1
                if next == "\n" || next == "\r\n" { flush() }
                else { token.append(next) }
            case "$":
                guard index < characters.count, characters[index] == "$" else { throw Unsupported.inputDescription }
                index += 1
                token.append("$")
            case ":":
                guard !inDependencies else { throw Unsupported.inputDescription }
                flush()
                inDependencies = true
            case " ", "\t": flush()
            case "\n", "\r\n": try finishRule()
            case "#":
                flush()
                while index < characters.count && characters[index] != "\n" && characters[index] != "\r\n" { index += 1 }
            default: token.append(character)
            }
        }
        try finishRule()
        guard ruleCount > 0 else { throw Unsupported.inputDescription }
        return (result, outputTargets)
    }

    private static func dependencyInfoInputs(_ data: Data, relativeTo directory: URL?) throws -> Inputs {
        let bytes = Array(data)
        var index = 0
        var versionSeen = false
        var result: Set<URL> = []
        var missing: Set<URL> = []
        while index < bytes.count {
            let kind = bytes[index]
            index += 1
            let begin = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            guard index < bytes.count, let value = String(bytes: bytes[begin..<index], encoding: .utf8) else {
                throw Unsupported.inputDescription
            }
            index += 1
            switch kind {
            case 0:
                guard !versionSeen, !value.isEmpty else { throw Unsupported.inputDescription }
                versionSeen = true
            case 0x10:
                guard versionSeen else { throw Unsupported.inputDescription }
                result.insert(try pathURL(value, relativeTo: directory))
            case 0x11:
                guard versionSeen else { throw Unsupported.inputDescription }
                missing.insert(try pathURL(value, relativeTo: directory))
            case 0x40:
                guard versionSeen else { throw Unsupported.inputDescription }
            default: throw Unsupported.inputDescription
            }
        }
        guard versionSeen else { throw Unsupported.inputDescription }
        return Inputs(files: result, missing: missing)
    }

    private static func collectResponseFiles(_ arguments: [String], relativeTo directory: URL?,
        syntax suppliedSyntax: ResponseFileSyntax? = nil, read: (URL) throws -> Data,
        into files: inout Set<URL>, visiting: Set<URL> = []) throws {
        guard arguments.contains(where: { $0.hasPrefix("@") }) else { return }
        let syntax: ResponseFileSyntax
        if let suppliedSyntax { syntax = suppliedSyntax }
        else {
            switch arguments.first.map({ URL(filePath: $0).lastPathComponent }) {
            case "clang", "clang++", "swift-frontend": syntax = .llvmGNU
            case "swift", "swiftc":
                guard !arguments.contains("-frontend"), !arguments.contains("-disallow-use-new-driver") else {
                    throw Unsupported.inputDescription
                }
                syntax = .swiftDriver
            default: throw Unsupported.inputDescription
            }
        }
        for argument in arguments where argument.hasPrefix("@") {
            let url = try pathURL(String(argument.dropFirst()), relativeTo: directory)
            guard !visiting.contains(url) else { throw Unsupported.inputDescription }
            files.insert(url)
            let nested = try responseArguments(read(url), syntax: syntax)
            try collectResponseFiles(nested, relativeTo: directory, syntax: syntax, read: read, into: &files,
                visiting: visiting.union([url]))
        }
    }

    private static func responseArguments(_ data: Data, syntax: ResponseFileSyntax) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw Unsupported.inputDescription
        }
        if syntax == .swiftDriver {
            // Swift's Darwin driver tokenizes individual lines, with comments and shell-quote toggling.
            return text.split { $0 == "\n" || $0 == "\r\n" }.flatMap { line -> [String] in
                if line.hasPrefix("//") { return [] }
                var tokens: [String] = []
                var token = ""
                var escaped = false
                var quoted = false
                for character in line {
                    if escaped { token.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" || character == "'" { quoted.toggle() }
                    else if character.isWhitespace && !quoted {
                        if !token.isEmpty { tokens.append(token); token = "" }
                    } else { token.append(character) }
                }
                if !token.isEmpty { tokens.append(token) }
                return tokens
            }
        }
        var result: [String] = []
        var token = ""
        var quote: Unicode.Scalar?
        var escaped = false
        var hasToken = false
        // LLVM GNU tokenization preserves escaped newlines and splits only ASCII space/tab/CR/LF.
        for character in text.unicodeScalars {
            if escaped {
                token.unicodeScalars.append(character)
                escaped = false
                hasToken = true
            } else if character == "\\" { escaped = true }
            else if let current = quote {
                if character == current { quote = nil }
                else { token.unicodeScalars.append(character) }
                hasToken = true
            } else if character == "\"" || character == "'" { quote = character; hasToken = true }
            else if character == " " || character == "\t" || character == "\r" || character == "\n" {
                if hasToken { result.append(token); token = ""; hasToken = false }
            } else { token.unicodeScalars.append(character); hasToken = true }
        }
        if escaped { token.append("\\"); hasToken = true }
        if hasToken { result.append(token) }
        return result
    }

    private static func absoluteNode(_ path: String) throws -> URL? {
        if path.hasPrefix("<"), path.hasSuffix(">") { return nil }
        return try absolutePath(path)
    }

    private static func absolutePath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Unsupported.inputDescription }
        return URL(filePath: path).standardizedFileURL
    }

    private static func pathURL(_ path: String, relativeTo directory: URL?) throws -> URL {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw Unsupported.inputDescription }
        if path.hasPrefix("/") { return try absolutePath(path) }
        guard let directory else { throw Unsupported.inputDescription }
        let base = URL(filePath: directory.path, directoryHint: .isDirectory)
        return URL(filePath: path, relativeTo: base).standardizedFileURL.absoluteURL
    }
}
