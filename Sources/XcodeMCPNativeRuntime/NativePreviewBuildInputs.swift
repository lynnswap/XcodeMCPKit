import Foundation

/// Reads the input side of one completed native build; generated descriptions and depfiles are discovery data.
struct NativePreviewBuildInputs {
    struct Inputs: Equatable {
        let files: Set<URL>
        let missing: Set<URL>
        let generatedPaths: Set<URL>
        let discoveryFiles: Set<URL>
        let generatedFiles: Set<URL>
        let generatedMissingFiles: Set<URL>

        init(files: Set<URL>, missing: Set<URL>, generatedPaths: Set<URL> = [], discoveryFiles: Set<URL> = []) {
            self.generatedPaths = generatedPaths
            self.discoveryFiles = discoveryFiles
            self.files = NativePreviewBuildInputs.removingGeneratedPaths(from: files, generatedPaths: discoveryFiles)
            self.missing = NativePreviewBuildInputs.removingGeneratedPaths(from: missing, generatedPaths: discoveryFiles)
                .subtracting(self.files)
            generatedFiles = self.files.subtracting(
                NativePreviewBuildInputs.removingGeneratedPaths(from: self.files, generatedPaths: generatedPaths))
            generatedMissingFiles = self.missing.subtracting(
                NativePreviewBuildInputs.removingGeneratedPaths(from: self.missing, generatedPaths: generatedPaths))
        }
    }

    static func removingGeneratedPaths(from files: Set<URL>, generatedPaths: Set<URL>) -> Set<URL> {
        let paths = Set(generatedPaths.map { $0.standardizedFileURL.path })
        return files.filter { file in
            // Non-filesystem source identifiers remain subject to the caller's input validation.
            guard file.isFileURL, file.path.hasPrefix("/") else { return true }
            var components = file.standardizedFileURL.pathComponents
            while !components.isEmpty {
                if paths.contains(NSString.path(withComponents: components)) { return false }
                components.removeLast()
            }
            return true
        }
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
        let description: String?
        let alwaysOutOfDate: Bool?

        func permitsBuildReuse(immutableRoots: [URL]) -> Bool {
            guard alwaysOutOfDate == true else { return true }
            // This sentinel varies only with the native build command, which is fixed for retained builds.
            if tool == "link-assetcatalog", description == "LinkAssetCatalogSignature" { return true }
            guard tool == "shell", let arguments = args, arguments.count >= 2,
                  arguments[0].hasPrefix("/"), arguments[1].hasPrefix("/"),
                  URL(filePath: arguments[0]).lastPathComponent == "clang-stat-cache" else { return false }
            // The SDK cache cannot change compilation inputs when both its tool and SDK are immutable.
            return arguments.prefix(2).allSatisfy { path in
                let input = URL(filePath: path).standardizedFileURL
                return immutableRoots.contains { root in
                    input.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
                        && input.resolvingSymlinksInPath().pathComponents.starts(
                            with: root.resolvingSymlinksInPath().pathComponents)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case tool, inputs, outputs, args, deps, description
            case dependencyStyle = "deps-style"
            case workingDirectory = "working-directory"
            case alwaysOutOfDate = "always-out-of-date"
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

    private struct ClangScan {
        let moduleOutput: String?
        let files: [String]
        let modules: [String]
        let workingDirectory: URL
        let scanningArguments: [String]

        init(_ data: Data) throws {
            var reader = ClangScanReader(bytes: Array(data))
            // Swift Build's DependencyInfo record includes the file and module dependency edges.
            guard try reader.arrayCount() == 10, try reader.arrayCount() == 2 else {
                throw Unsupported.inputDescription
            }
            let kind = try reader.integer()
            moduleOutput = try reader.optionalString()
            guard (kind == 0 && moduleOutput == nil) || (kind == 1 && moduleOutput != nil) else {
                throw Unsupported.inputDescription
            }
            files = try reader.strings()
            _ = try reader.optionalString() // Include-tree CAS ID.
            modules = try reader.strings()
            workingDirectory = URL(filePath: try absolutePath(reader.string()).path, directoryHint: .isDirectory)
            let commandCount = try reader.arrayCount()
            for _ in 0..<commandCount {
                guard try reader.arrayCount() == 2 else { throw Unsupported.inputDescription }
                _ = try reader.optionalString() // Compile-command cache key.
                _ = try reader.strings()
            }
            scanningArguments = try reader.strings()
            _ = try reader.strings() // Transitive include-tree CAS IDs.
            _ = try reader.strings() // Transitive compile-command cache keys.
            try reader.boolean()
            guard reader.isAtEnd else { throw Unsupported.inputDescription }
        }
    }

    /// Reads only the MessagePack types used by the native Clang DependencyInfo record.
    private struct ClangScanReader {
        let bytes: [UInt8]
        private var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset == bytes.count }

        private mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Unsupported.inputDescription }
            defer { offset += 1 }
            return bytes[offset]
        }

        private mutating func unsigned(_ count: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<count { value = (value << 8) | UInt64(try byte()) }
            return value
        }

        mutating func integer() throws -> Int {
            let marker = try byte()
            if marker <= 0x7f { return Int(marker) }
            guard marker == 0xd3 else { throw Unsupported.inputDescription }
            return Int(Int64(bitPattern: try unsigned(8)))
        }

        mutating func arrayCount() throws -> Int {
            let marker = try byte()
            let count: Int
            switch marker {
            case 0x90...0x9f: count = Int(marker & 0x0f)
            case 0xdc: count = Int(try unsigned(2))
            case 0xdd: count = Int(try unsigned(4))
            default: throw Unsupported.inputDescription
            }
            guard count <= bytes.count - offset else { throw Unsupported.inputDescription }
            return count
        }

        mutating func string() throws -> String {
            let marker = try byte()
            let count: Int
            switch marker {
            case 0xa0...0xbf: count = Int(marker & 0x1f)
            case 0xd9: count = Int(try unsigned(1))
            case 0xda: count = Int(try unsigned(2))
            case 0xdb: count = Int(try unsigned(4))
            default: throw Unsupported.inputDescription
            }
            guard count <= bytes.count - offset,
                  let value = String(bytes: bytes[offset..<(offset + count)], encoding: .utf8) else {
                throw Unsupported.inputDescription
            }
            offset += count
            return value
        }

        mutating func optionalString() throws -> String? {
            guard offset < bytes.count else { throw Unsupported.inputDescription }
            if bytes[offset] == 0xc0 { offset += 1; return nil }
            return try string()
        }

        mutating func strings() throws -> [String] {
            let count = try arrayCount()
            return try (0..<count).map { _ in try string() }
        }

        mutating func boolean() throws {
            let marker = try byte()
            guard marker == 0xc2 || marker == 0xc3 else { throw Unsupported.inputDescription }
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
            guard !manifest.commands.isEmpty,
                  manifest.commands.values.allSatisfy({ $0.permitsBuildReuse(immutableRoots: immutableRoots) }) else {
                throw Unsupported.inputDescription
            }
            let produced = try Set(manifest.commands.values.flatMap(\.outputs).compactMap { path in
                try absoluteNode(path)
            })
            let clangScanOutputs = try Set(manifest.commands.values.filter { $0.tool == "clang-scan-modules" }
                .flatMap(\.outputs).compactMap { try absoluteNode($0) })
            var nativeClangScans: Set<URL> = []
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
                if command.tool == "ccompile", command.deps == nil {
                    let scans = try Set((command.inputs ?? []).compactMap { try absoluteNode($0) })
                        .intersection(clangScanOutputs)
                    guard !scans.isEmpty else { throw Unsupported.inputDescription }
                    nativeClangScans.formUnion(scans)
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
            var pendingClangScans = nativeClangScans.map { (url: $0, moduleOutput: Optional<URL>.none) }
            var parsedClangScans: [URL: ClangScan] = [:]
            while let next = pendingClangScans.popLast() {
                let scan: ClangScan
                let newlyRead: Bool
                if let existing = parsedClangScans[next.url] { scan = existing; newlyRead = false }
                else {
                    scan = try ClangScan(readDescription(next.url))
                    parsedClangScans[next.url] = scan
                    dependencyFiles.insert(next.url)
                    newlyRead = true
                }
                guard try scan.moduleOutput.map({ try absolutePath($0) }) == next.moduleOutput else {
                    throw Unsupported.inputDescription
                }
                guard newlyRead else { continue }
                let directory = scan.workingDirectory
                inputs.formUnion(try scan.files.map { try pathURL($0, relativeTo: directory) })
                for path in scan.modules {
                    let module = try pathURL(path, relativeTo: directory)
                    inputs.insert(module)
                    // Swift Build stores each PCM's own file and module dependencies beside it.
                    pendingClangScans.append((module.deletingPathExtension().appendingPathExtension("scan"), module))
                }
                if next.moduleOutput == nil {
                    // Module records can repeat another scan's argv with an intentionally ignored CWD.
                    try collectResponseFiles(scan.scanningArguments, relativeTo: directory, syntax: .llvmGNU,
                        read: readDescription, into: &responseFiles)
                }
            }
            for command in compilerCommands {
                try collectResponseFiles(command.arguments, relativeTo: command.workingDirectory,
                    syntax: command.responseFileSyntax, read: readDescription, into: &responseFiles)
            }
            inputs.formUnion(responseFiles)
            let discoveryFiles = dependencyFiles.union([manifestURL.standardizedFileURL])
            func tracked(_ files: Set<URL>) -> Set<URL> {
                files.filter { input in
                    !immutableRoots.contains { root in
                        input.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
                            && input.resolvingSymlinksInPath().pathComponents.starts(
                                with: root.resolvingSymlinksInPath().pathComponents)
                    }
                }
            }
            return Inputs(files: tracked(inputs), missing: tracked(missing), generatedPaths: produced.union(discoveryFiles),
                discoveryFiles: discoveryFiles)
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
        let normalized = URL(filePath: path).standardizedFileURL
        // XCBuild directory-tree nodes can name a file output with a trailing slash.
        return URL(filePath: normalized.path, directoryHint: .notDirectory)
    }

    private static func pathURL(_ path: String, relativeTo directory: URL?) throws -> URL {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw Unsupported.inputDescription }
        if path.hasPrefix("/") { return try absolutePath(path) }
        guard let directory else { throw Unsupported.inputDescription }
        let base = URL(filePath: directory.path, directoryHint: .isDirectory)
        return try absolutePath(URL(filePath: path, relativeTo: base).standardizedFileURL.absoluteURL.path)
    }
}
