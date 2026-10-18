import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

struct NativePreviewBuildInputsTests {
    private let manifest = URL(filePath: "/build/native.xcbuilddata/manifest.json")

    @Test func makefileEscapesContinuationsAndPhonyHeaderRules() throws {
        let data = Data(##"""
        /build/A.o /build/A.swiftmodule: /user/Bridge\ Header.h \
          /user/Value\#1.h /user/Dollar$$.h /user/Colon\:value.h /user/Back\\slash.h
        /user/Bridge\ Header.h:
        """##.utf8)
        let inputs = try NativePreviewBuildInputs.makefileInputs(data, relativeTo: nil)
        #expect(inputs == Set(["/user/Bridge Header.h", "/user/Value#1.h", "/user/Dollar$.h",
            "/user/Colon:value.h", "/user/Back\\slash.h"].map { URL(filePath: $0) }))
    }

    @Test func relativeDepfileInputsUseEachCommandWorkingDirectory() throws {
        let first = URL(filePath: "/build/First.d")
        let second = URL(filePath: "/build/Second.d")
        let data = try json(["commands": [
            "first": ["tool": "shell", "outputs": ["/build/First.o"], "deps": first.path,
                "deps-style": "makefile", "working-directory": "/project/first"],
            "second": ["tool": "shell", "outputs": ["/build/Second.o"], "deps": second.path,
                "deps-style": "makefile", "working-directory": "/project/second"]
        ]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data,
            first: Data("/build/First.o: Shared.h\n".utf8),
            second: Data("/build/Second.o: Shared.h\n".utf8)
        ]))
        #expect(files?.files == [URL(filePath: "/project/first/Shared.h"), URL(filePath: "/project/second/Shared.h")])
    }

    @Test func externalPlistSurvivesProducedAndInstallationInputExclusion() throws {
        let data = try json(["commands": [
            "plist": ["tool": "info-plist-processor", "inputs": ["/user/External Inputs/Info.plist", "<entry>"],
                "outputs": ["/build/App.app/Info.plist"]],
            "generated": ["tool": "auxiliary-file", "outputs": ["/build/generated.h", "/build/GeneratedResources/", "/build/Schema.json"]],
            "codegen": ["tool": "shell", "inputs": ["/build/Schema.json"], "outputs": ["/build/Generated.swift"]],
            "compile": ["tool": "shell", "inputs": ["/build/generated.h/", "/build/GeneratedResources/Icon.txt",
                "/SelectedXcode/SDK/Header.h",
                "/System/Library/Frameworks/UIKit.framework/UIKit", "/System/Library/AssetsV2/Mutable.asset"],
                "outputs": ["/build/A.o"]]
        ]])
        let files = NativePreviewBuildInputs.files(manifest: manifest,
            immutableRoots: [URL(filePath: "/SelectedXcode"), URL(filePath: "/System/Library/Frameworks")],
            read: reader([manifest: data]))
        #expect(files?.files == [URL(filePath: "/user/External Inputs/Info.plist"),
            URL(filePath: "/System/Library/AssetsV2/Mutable.asset"), URL(filePath: "/build/generated.h"),
            URL(filePath: "/build/GeneratedResources/Icon.txt"), URL(filePath: "/build/Schema.json")])
    }

    @Test func alwaysExecutingCommandsRequireKnownStableEffects() throws {
        let immutableRoot = URL(filePath: "/SelectedXcode")
        func inputs(_ commands: [String: [String: Any]]) throws -> NativePreviewBuildInputs.Inputs? {
            let data = try json(["commands": commands])
            return NativePreviewBuildInputs.files(manifest: manifest, immutableRoots: [immutableRoot],
                read: reader([manifest: data]))
        }
        let external: [String: Any] = ["tool": "shell", "description": "ExternalBuildToolExecution Generator",
            "inputs": [], "outputs": ["<build-tool-generator>"],
            "args": ["/tools/generate-header"], "always-out-of-date": true]
        #expect(try inputs(["external": external]) == nil)

        let statCache: [String: Any] = ["tool": "shell", "description": "ClangStatCache",
            "inputs": [], "outputs": ["/build/SDK.sdkstatcache", "<ClangStatCache /build/SDK.sdkstatcache>"],
            "args": ["/SelectedXcode/usr/bin/clang-stat-cache", "/SelectedXcode/SDK", "-o", "/build/SDK.sdkstatcache"],
            "always-out-of-date": true]
        let assetSignature: [String: Any] = ["tool": "link-assetcatalog", "description": "LinkAssetCatalogSignature",
            "inputs": [], "outputs": ["/build/assetcatalog_signature"], "always-out-of-date": true]
        let compile: [String: Any] = ["tool": "shell", "inputs": ["/user/A.swift"], "outputs": ["/build/A.o"]]
        var commands = ["stat": statCache, "assets": assetSignature, "compile": compile]
        #expect(try inputs(commands)?.files == [URL(filePath: "/user/A.swift")])

        for arguments in [
            ["/mutable/clang-stat-cache", "/SelectedXcode/SDK", "-o", "/build/SDK.sdkstatcache"],
            ["/SelectedXcode/usr/bin/clang-stat-cache", "/mutable/SDK", "-o", "/build/SDK.sdkstatcache"]
        ] {
            var mutableCache = statCache
            mutableCache["args"] = arguments
            commands["stat"] = mutableCache
            #expect(try inputs(commands) == nil)
        }
        commands["stat"] = statCache
        var unknownAssetAction = assetSignature
        unknownAssetAction["description"] = "OtherAssetAction"
        commands["assets"] = unknownAssetAction
        #expect(try inputs(commands) == nil)
    }

    @Test func nativeOrderingNodesDoNotBecomeFilesystemInputs() throws {
        let parent = "/build"
        let cache = "/global/ModuleCache.noindex"
        let generated = "/build/Generated.swift"
        let schema = "/build/Schema.json"
        let object = "/build/Generated.o"
        let marker = "/build/Swift Compilation Finished"
        let tree = "/build/Resources/"
        let virtual = "/build/Virtual"
        let timestamp = "/build/Command Timestamp"
        let dependency = URL(filePath: "/build/Generated.d")
        let nodes: [String: [String: Bool]] = [
            parent: ["is-mutated": true], cache: ["is-mutated": true],
            schema: ["is-mutated": true], tree: ["is-mutated": true, "is-directory": true],
            virtual: ["is-virtual": true], timestamp: ["is-command-timestamp": true]
        ]
        var commands: [String: [String: Any]] = [
            "all": ["tool": "phony", "inputs": [cache, marker], "outputs": ["<all>"]],
            "parent": ["tool": "create-build-directory", "inputs": ["/ordering/Ancestor"], "outputs": [parent]],
            "cache": ["tool": "create-build-directory", "inputs": [], "outputs": [cache]],
            "tree": ["tool": "create-build-directory", "inputs": [], "outputs": [tree]],
            "app": ["tool": "mkdir", "inputs": ["/ordering/Mkdir"], "outputs": ["/build/App"]],
            "generated": ["tool": "auxiliary-file", "inputs": [parent], "outputs": [generated, schema, marker]],
            "codegen": ["tool": "shell", "inputs": [schema], "outputs": ["/build/Other.swift"]],
            "compile": ["tool": "shell", "inputs": [generated, parent, virtual, timestamp, "/external/Header.h"], "outputs": [object]],
            "link": ["tool": "shell", "inputs": [object, parent, tree], "outputs": ["/build/App/Executable"]]
        ]
        let expected = Set([generated, schema, object, String(tree.dropLast()), "/external/Header.h"].map { URL(filePath: $0) })
        let data = try json(["commands": commands, "nodes": nodes])
        let inputs = NativePreviewBuildInputs.files(manifest: manifest, read: reader([manifest: data]))
        #expect(inputs?.files == expected)

        // Dynamic dependency records identify actual content even when a plain build-directory node also exists.
        commands["compile"]?["deps"] = dependency.path
        commands["compile"]?["deps-style"] = "makefile"
        let dynamic = try json(["commands": commands, "nodes": nodes])
        let dynamicInputs = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: dynamic, dependency: Data("/build/Generated.o: /build/\n".utf8)
        ]))
        #expect(dynamicInputs?.files == expected.union([URL(filePath: parent)]))
    }

    @Test func generatedPathFilteringPreservesNonFileSourceIdentifiers() throws {
        let relative = try #require(URL(string: "relative.swift"))
        let remote = try #require(URL(string: "https://example.invalid/build/Generated/Source.swift"))
        let files: Set<URL> = [relative, remote]
        #expect(NativePreviewBuildInputs.removingGeneratedPaths(from: files,
            generatedPaths: [URL(filePath: "/build/Generated")]) == files)
    }

    @Test func generatedPathFilteringUsesWholeNormalizedAncestors() {
        let root = URL(filePath: "/build/生成物")
        let direct = root.appendingPathComponent("Source.swift")
        let nested = root.appendingPathComponent("Nested/../子/Source.swift")
        let sibling = URL(filePath: "/build/生成物-other/Source.swift")
        let inputs: Set<URL> = [root, direct, nested, sibling]
        #expect(NativePreviewBuildInputs.removingGeneratedPaths(from: inputs, generatedPaths: [root]) == [sibling])
        #expect(NativePreviewBuildInputs.removingGeneratedPaths(from: inputs, generatedPaths: [URL(filePath: "/")]).isEmpty)
        #expect(NativePreviewBuildInputs.removingGeneratedPaths(from: inputs, generatedPaths: []) == inputs)
    }

    @Test func swiftOutputMapFindsTransitiveHeadersAndModuleDependencies() throws {
        let map = URL(filePath: "/build/Target-OutputFileMap.json")
        let objectDependencies = URL(filePath: "/build/A.d")
        let moduleDependencies = URL(filePath: "/build/Target-module.d")
        let generated = "/build/Generated.swift"
        let data = try json(["commands": [
            "swift": ["tool": "swift-driver-compilation", "inputs": [map.path, generated, "<target-GeneratedHeaders>"],
                "outputs": ["/build/Swift Compilation Finished", "/build/A.o"]],
            "requirements": ["tool": "swift-driver-compilation-requirement", "inputs": [map.path, generated],
                "outputs": ["/build/Swift Compilation Requirements Finished", "/build/Target.swiftmodule"]],
            "generated": ["tool": "auxiliary-file", "outputs": [generated]]
        ]])
        let mapData = try json(["/user/A.swift": ["object": "/build/A.o", "dependencies": objectDependencies.path],
            "": ["emit-module-dependencies": moduleDependencies.path]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, map: mapData,
            objectDependencies: Data("/build/A.o: /user/A.swift /user/Bridge\\ Header.h /user/Leaf.h /build/Generated.swift\n".utf8),
            moduleDependencies: Data("/build/Target.swiftmodule: /user/ModuleOnly.h\n".utf8)
        ]))
        #expect(files?.files == Set(["/user/A.swift", "/user/Bridge Header.h", "/user/Leaf.h", "/user/ModuleOnly.h", generated].map { URL(filePath: $0) }))
        #expect(files?.files.contains(map) == false)
        #expect(files?.files.contains(objectDependencies) == false)
        #expect(files?.files.contains(moduleDependencies) == false)
    }

    @Test func wholeModuleDepfileCoversRequirementObjectsAndModuleWithoutUnusedSplitDepfile() throws {
        let map = URL(filePath: "/build/Target-OutputFileMap.json")
        let primary = URL(filePath: "/build/Target-primary.d")
        let data = try json(["commands": [
            "swift": ["tool": "swift-driver-compilation", "inputs": [map.path],
                "outputs": ["/build/Swift Compilation Finished"]],
            "requirements": ["tool": "swift-driver-compilation-requirement", "inputs": [map.path],
                "outputs": ["/build/A.o", "/build/B.o", "/build/Target.swiftmodule"]]
        ]])
        let mapData = try json(["/user/A.swift": ["object": "/build/A.o"],
            "/user/B.swift": ["object": "/build/B.o"],
            "": ["dependencies": primary.path, "emit-module-dependencies": "/build/unused-emit-module.d"]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, map: mapData,
            primary: Data("/build/A.o /build/B.o: /user/A.swift /user/B.swift /user/Bridge\\ Header.h /user/Leaf.h\n/build/Target.swiftmodule: /user/ModuleOnly.h\n".utf8)
        ]))
        #expect(files?.files == Set(["/user/A.swift", "/user/B.swift", "/user/Bridge Header.h", "/user/Leaf.h",
            "/user/ModuleOnly.h"].map { URL(filePath: $0) }))
    }

    @Test func swiftDepfileMustCoverEveryMappedObject() throws {
        let map = URL(filePath: "/build/Target-OutputFileMap.json")
        let primary = URL(filePath: "/build/Target-primary.d")
        let data = try json(["commands": ["swift": ["tool": "swift-driver-compilation",
            "inputs": [map.path], "outputs": ["/build/A.o", "/build/B.o"]]]])
        let mapData = try json(["/user/A.swift": ["object": "/build/A.o"],
            "/user/B.swift": ["object": "/build/B.o"], "": ["dependencies": primary.path]])
        #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, map: mapData, primary: Data("/build/A.o: /user/A.swift\n".utf8)
        ])) == nil)
    }

    @Test func missingSeparateModuleDepfileDisablesCertification() throws {
        let map = URL(filePath: "/build/Target-OutputFileMap.json")
        let objectDependencies = URL(filePath: "/build/A.d")
        let data = try json(["commands": [
            "swift": ["tool": "swift-driver-compilation", "inputs": [map.path], "outputs": ["/build/A.o"]],
            "requirements": ["tool": "swift-driver-compilation-requirement", "inputs": [map.path],
                "outputs": ["/build/Target.swiftmodule"]]
        ]])
        let mapData = try json(["/user/A.swift": ["object": "/build/A.o", "dependencies": objectDependencies.path],
            "": ["emit-module-dependencies": "/build/Target-emit-module.d"]])
        #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, map: mapData, objectDependencies: Data("/build/A.o: /user/A.swift\n".utf8)
        ])) == nil)
    }

    @Test func clangDeclaredDepfileAndNestedResponseFiles() throws {
        let dependency = URL(filePath: "/build/A.d")
        let outer = URL(filePath: "/user/Outer Flags.rsp")
        let inner = URL(filePath: "/user/Inner Flags.rsp")
        let data = try json(["commands": ["compile": ["tool": "shell", "inputs": ["/user/A.c"],
            "outputs": ["/build/A.o"], "args": ["clang", "-c", "@" + outer.path],
            "deps": [dependency.path], "deps-style": "makefile", "working-directory": "/project"],
            "generated": ["tool": "auxiliary-file", "outputs": ["/project/Generated"]]]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, dependency: Data("/build/A.o: local\\ header.h ../external\\ header.h Generated/\n".utf8),
            outer: Data("'@/user/Inner Flags.rsp' -DNUMBER=42".utf8), inner: Data("-DSECOND=1".utf8)
        ]))
        #expect(files?.files == Set(["/user/A.c", "/project/local header.h", "/external header.h", "/project/Generated", outer.path, inner.path].map { URL(filePath: $0) }))
    }

    @Test func nativeClangScanTracksHeadersModulesAndNestedResponseFiles() throws {
        let scan = URL(filePath: "/build/A.o.scan")
        let module = URL(filePath: "/build/Modules/Support.pcm")
        let moduleScan = URL(filePath: "/build/Modules/Support.scan")
        let sharedModule = URL(filePath: "/build/Modules/Shared.pcm")
        let sharedScan = URL(filePath: "/build/Modules/Shared.scan")
        let outer = URL(filePath: "/external/Compiler Flags.rsp")
        let inner = URL(filePath: "/external/Nested Flags.rsp")
        let data = try json(["commands": [
            "scan": ["tool": "clang-scan-modules", "inputs": ["/user/A.c"], "outputs": [scan.path]],
            "compile": ["tool": "ccompile", "inputs": ["/user/A.c", scan.path], "outputs": ["/build/A.o"]],
            "generated": ["tool": "auxiliary-file", "outputs": ["/build/Generated.h"]]
        ]])
        let descriptions = [
            manifest: data,
            scan: clangScan(files: ["/user/A.c", "/external/Leaf.h", "/build/Generated.h"],
                modules: [module.path, sharedModule.path],
                arguments: ["clang", "-c", "@../external/Compiler Flags.rsp"]),
            moduleScan: clangScan(module: module.path, files: ["/external/ModuleLeaf.h"], modules: [sharedModule.path]),
            sharedScan: clangScan(module: sharedModule.path, files: ["/external/SharedLeaf.h"]),
            outer: Data("'@../external/Nested Flags.rsp' -DNUMBER=42".utf8),
            inner: Data("-DSECOND=1".utf8)
        ]
        let inputs = NativePreviewBuildInputs.files(manifest: manifest, read: reader(descriptions))
        #expect(inputs?.files == Set(["/user/A.c", "/external/Leaf.h", "/external/ModuleLeaf.h",
            "/external/SharedLeaf.h", "/build/Generated.h", module.path, sharedModule.path, outer.path, inner.path].map { URL(filePath: $0) }))
        #expect(inputs?.files.isDisjoint(with: [scan, moduleScan, sharedScan]) == true)
    }

    @Test func nativeClangDirectoryScansTrackModuleListingsWithoutTreatingCASAsPaths() throws {
        let scan = URL(filePath: "/build/A.o.scan")
        let module = URL(filePath: "/build/Modules/Support.pcm")
        let moduleScan = URL(filePath: "/build/Modules/Support.scan")
        let source = URL(filePath: "/user/A.c")
        let header = URL(filePath: "/external/Support.framework/Headers/Leaf.h")
        let headers = URL(filePath: "/external/Support.framework/Headers")
        let data = try json(["commands": [
            "scan": ["tool": "clang-scan-modules", "inputs": [source.path], "outputs": [scan.path]],
            "compile": ["tool": "ccompile", "inputs": [source.path, scan.path], "outputs": ["/build/A.o"]]
        ]])
        let descriptions = [
            manifest: data,
            scan: clangScan(files: [source.path], modules: [module.path], directories: []),
            moduleScan: clangScan(module: module.path, files: [header.path], directories: [headers.path])
        ]
        let inputs = NativePreviewBuildInputs.files(manifest: manifest, read: reader(descriptions))
        // The directory listing is a dependency even though the TU only names the PCM.
        // Exact equality also excludes nonempty CAS/cache strings and .scan metadata paths.
        #expect(inputs?.files == Set([source, module, header, headers]))
    }

    @Test func incompleteNativeClangScansDisableCertification() throws {
        let scan = URL(filePath: "/build/A.o.scan")
        let data = try json(["commands": [
            "scan": ["tool": "clang-scan-modules", "inputs": ["/user/A.c"], "outputs": [scan.path]],
            "compile": ["tool": "ccompile", "inputs": ["/user/A.c", scan.path], "outputs": ["/build/A.o"]]
        ]])
        for unknownSchema in [false, true] {
            let description = clangScan(files: ["/user/A.c"], modules: unknownSchema ? [] : ["/build/Modules/Missing.pcm"],
                unknownSchema: unknownSchema)
            #expect(NativePreviewBuildInputs.files(manifest: manifest,
                read: reader([manifest: data, scan: description])) == nil)
        }
    }

    @Test func unknownOrUnreadDynamicDependenciesDisableOnlyTheCertificate() throws {
        let dependency = URL(filePath: "/build/A.deps")
        for style in ["unknown-format", "makefile"] {
            let data = try json(["commands": ["compile": ["tool": "shell", "inputs": ["/user/A.c"],
                "outputs": ["/build/A.o"], "deps": dependency.path, "deps-style": style]]])
            var descriptions = [manifest: data]
            if style == "unknown-format" { descriptions[dependency] = Data("/build/A.o: /user/A.c\n".utf8) }
            #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader(descriptions)) == nil)
        }
        let malformed = Data("/build/A.o: $(UNEXPANDED_HEADER)\n".utf8)
        #expect(throws: (any Error).self) {
            try NativePreviewBuildInputs.makefileInputs(malformed, relativeTo: nil)
        }
    }

    @Test func nativeDependencyInfoKeepsMissingInputsAndIgnoresProducedOutputs() throws {
        let dependency = URL(filePath: "/build/link.dat")
        var info = Data([0]); info.append(Data("ld64\0".utf8))
        info.append(0x10); info.append(Data("/user/libSupport.a\0".utf8))
        info.append(0x11); info.append(Data("/user/libSupport.a\0".utf8))
        info.append(0x11); info.append(Data("/user/Optional.tbd\0".utf8))
        info.append(0x10); info.append(Data("/build/Search/Present.a\0".utf8))
        info.append(0x11); info.append(Data("/build/Search/Present.a\0".utf8))
        info.append(0x11); info.append(Data("/build/Search/Optional.tbd\0".utf8))
        info.append(0x40); info.append(Data("/build/App\0".utf8))
        for tool in ["shell", "linker", "embed-swift-stdlib", "link-assetcatalog"] {
            var command: [String: Any] = ["tool": tool, "inputs": [], "outputs": ["/build/App"],
                "deps": [dependency.path]]
            if tool == "shell" { command["deps-style"] = "dependency-info" }
            let data = try json(["commands": ["link": command,
                "directory": ["tool": "mkdir", "outputs": ["/build/Search/"]]]])
            let inputs = NativePreviewBuildInputs.files(manifest: manifest, read: reader([manifest: data, dependency: info]))
            #expect(inputs?.files == [URL(filePath: "/user/libSupport.a"), URL(filePath: "/build/Search/Present.a")])
            #expect(inputs?.missing == [URL(filePath: "/user/Optional.tbd"), URL(filePath: "/build/Search/Optional.tbd")])
        }
    }

    @Test func responseFileDialectsKeepTheirNativeNestedPaths() throws {
        let data = try json(["commands": ["copy": ["tool": "file-copy", "inputs": [], "outputs": ["/build/A.txt"]]]])
        let outer = URL(filePath: "/flags/Outer.rsp")
        let newline = URL(filePath: "/project/Line\nBreak.rsp")
        let nonbreakingSpace = URL(filePath: "/project/Wide\u{a0}Name.rsp")
        let gnu = NativePreviewBuildInputs.files(manifest: manifest,
            compilerCommands: [.init(arguments: ["clang", "-c", "@" + outer.path], workingDirectory: URL(filePath: "/project"))],
            read: reader([manifest: data, outer: Data("@Line\\\nBreak.rsp @Wide\u{a0}Name.rsp".utf8),
                newline: Data(), nonbreakingSpace: Data()]))
        #expect(gnu?.files == Set([outer, newline, nonbreakingSpace]))
        let first = URL(filePath: "/custom/First File.rsp")
        let second = URL(filePath: "/custom/Second.rsp")
        let swift = NativePreviewBuildInputs.files(manifest: manifest,
            compilerCommands: [.init(arguments: ["@" + outer.path], workingDirectory: URL(filePath: "/custom"),
                responseFileSyntax: .swiftDriver)],
            read: reader([manifest: data, outer: Data("// @Ignored.rsp\n@'First File.rsp'\n-DVALUE=1\u{a0}@Second.rsp".utf8),
                first: Data(), second: Data()]))
        #expect(swift?.files == Set([outer, first, second]))
    }

    private func clangScan(module: String? = nil, files: [String], modules: [String] = [],
                           arguments: [String] = ["clang", "-c"], directories: [String]? = nil,
                           unknownSchema: Bool = false) -> Data {
        func array(_ elements: [Data]) -> Data {
            var data = elements.count < 16 ? Data([0x90 | UInt8(elements.count)])
                : Data([0xdc, UInt8(truncatingIfNeeded: elements.count >> 8), UInt8(truncatingIfNeeded: elements.count)])
            for element in elements { data.append(element) }
            return data
        }
        func string(_ value: String) -> Data {
            let bytes = Data(value.utf8)
            var data: Data
            if bytes.count < 32 { data = Data([0xa0 | UInt8(bytes.count)]) }
            else if bytes.count < 256 { data = Data([0xd9, UInt8(bytes.count)]) }
            else { data = Data([0xda, UInt8(truncatingIfNeeded: bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)]) }
            data.append(bytes)
            return data
        }
        let nilValue = Data([0xc0])
        let kind = array([Data([0xd3, 0, 0, 0, 0, 0, 0, 0, module == nil ? 0 : 1]), module.map(string) ?? nilValue])
        let cacheKey = directories == nil ? nilValue : string("llvmcas://command-cache-key")
        let command = array([cacheKey, array(["clang", "-cc1", "-o", module ?? "/build/A.o"].map(string))])
        var fields: [Data]
        if let directories {
            let includeTrees = module == nil ? [string("llvmcas://transitive-include-tree")] : []
            let cacheKeys = module == nil ? [string("llvmcas://transitive-command-cache-key")] : []
            fields = [array(includeTrees), kind, array(files.map(string)), array(directories.map(string)),
                string("llvmcas://include-tree"), array(modules.map(string)), string("/project"),
                array([command]), array(arguments.map(string)), array(cacheKeys), Data([0xc3])]
        } else {
            fields = [kind, array(files.map(string)), nilValue, array(modules.map(string)), string("/project"),
                array([command]), array(arguments.map(string)), array([]), array([]), Data([0xc3])]
        }
        if unknownSchema { fields.append(nilValue) }
        return array(fields)
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func reader(_ files: [URL: Data]) -> (URL) throws -> Data {
        { url in
            guard let data = files[url] else { throw CocoaError(.fileReadNoSuchFile) }
            return data
        }
    }

    @Test func linkedAssetCatalogDependencyInfoCoversSelectedVariant() throws {
        let descriptions = try linkedAssetCatalogFixture()
        let inputs = try #require(NativePreviewBuildInputs.files(manifest: manifest, read: reader(descriptions)))
        #expect(inputs.files.isSuperset(of: Set(["/user/App.xcassets", "/user/Particle.xcassets", "/user/Preview.xcassets",
            "/external/Shared.asset"].map { URL(filePath: $0) })))
        #expect(inputs.missing == [URL(filePath: "/external/Optional.asset")])
        #expect(inputs.discoveryFiles == [manifest, URL(filePath: "/build/assetcatalog_dependencies")])
        #expect(inputs.generatedFiles.isSuperset(of: [URL(filePath: "/build/assetcatalog_output/thinned"),
            URL(filePath: "/build/assetcatalog_output/unthinned")]))
    }

    @Test func linkedAssetCatalogRequiresFinalDependencyInfoAndUnrelatedCompileDependencies() throws {
        let dependency = URL(filePath: "/build/assetcatalog_dependencies")
        for replacement in [Optional<Data>.none, Data([0xff])] {
            var descriptions = try linkedAssetCatalogFixture()
            descriptions[dependency] = replacement
            #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader(descriptions)) == nil)
        }
        var noConsumer = try linkedAssetCatalogFixture()
        var noConsumerContents = try #require(JSONSerialization.jsonObject(with: noConsumer[manifest]!) as? [String: Any])
        var noConsumerCommands = try #require(noConsumerContents["commands"] as? [String: [String: Any]])
        noConsumerCommands.removeValue(forKey: "link")
        noConsumerContents["commands"] = noConsumerCommands
        noConsumer[manifest] = try json(noConsumerContents)
        #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader(noConsumer)) == nil)
        var descriptions = try linkedAssetCatalogFixture()
        var contents = try #require(JSONSerialization.jsonObject(with: descriptions[manifest]!) as? [String: Any])
        var commands = try #require(contents["commands"] as? [String: [String: Any]])
        commands["unrelated-compile"] = ["tool": "shell", "inputs": ["/user/Other.c"], "outputs": ["/build/Other.o"],
            "deps": "/build/Other.d", "deps-style": "makefile"]
        contents["commands"] = commands
        descriptions[manifest] = try json(contents)
        #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader(descriptions)) == nil)
    }

    private func linkedAssetCatalogFixture() throws -> [URL: Data] {
        let assets = ["/user/App.xcassets/", "/user/Particle.xcassets/", "/user/Preview.xcassets/"]
        var commands: [String: [String: Any]] = [:]
        for variant in ["thinned", "unthinned"] {
            let output = "/build/assetcatalog_output/" + variant
            let dependency = "/build/assetcatalog_dependencies_" + variant
            commands[variant] = ["tool": "shell", "inputs": assets + [output],
                "outputs": [output + "/", dependency, "/build/assetcatalog_generated_info.plist_" + variant],
                "args": ["/SelectedXcode/usr/bin/actool", "--compile", output, "--export-dependency-info", dependency],
                "working-directory": "/project", "deps": [dependency], "deps-style": "dependency-info"]
            commands["mkdir-" + variant] = ["tool": "mkdir", "inputs": [], "outputs": [output]]
        }
        commands["signature"] = ["tool": "link-assetcatalog", "description": "LinkAssetCatalogSignature",
            "inputs": [], "outputs": ["/build/assetcatalog_signature"], "always-out-of-date": true]
        commands["link"] = ["tool": "link-assetcatalog",
            "inputs": assets + ["/build/assetcatalog_output/thinned/", "/build/assetcatalog_output/unthinned/", "/build/assetcatalog_signature"],
            "outputs": ["/build/App.app/Assets.car", "/build/assetcatalog_generated_info.plist"],
            "deps": "/build/assetcatalog_dependencies"]
        var dependencyInfo = Data([0]); dependencyInfo.append(Data("actool\0".utf8))
        for asset in assets.map({ String($0.dropLast()) }) + ["/external/Shared.asset"] {
            dependencyInfo.append(0x10); dependencyInfo.append(Data((asset + "\0").utf8))
        }
        dependencyInfo.append(0x11); dependencyInfo.append(Data("/external/Optional.asset\0".utf8))
        dependencyInfo.append(0x40); dependencyInfo.append(Data("/build/assetcatalog_output/unthinned/Assets.car\0".utf8))
        return [manifest: try json(["commands": commands]), URL(filePath: "/build/assetcatalog_dependencies"): dependencyInfo]
    }

}
