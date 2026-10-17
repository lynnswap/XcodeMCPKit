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

    @Test func externalPlistSurvivesProducedAndInstallationInputExclusion() throws {
        let data = try json(["commands": [
            "plist": ["tool": "info-plist-processor", "inputs": ["/user/External Inputs/Info.plist", "<entry>"],
                "outputs": ["/build/App.app/Info.plist"]],
            "generated": ["tool": "auxiliary-file", "outputs": ["/build/generated.h"]],
            "compile": ["tool": "shell", "inputs": ["/build/generated.h", "/SelectedXcode/SDK/Header.h"],
                "outputs": ["/build/A.o"]]
        ]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, immutableRoots: [URL(filePath: "/SelectedXcode")],
            read: reader([manifest: data]))
        #expect(files == [URL(filePath: "/user/External Inputs/Info.plist")])
    }

    @Test func swiftOutputMapFindsTransitiveHeadersAndModuleDependencies() throws {
        let map = URL(filePath: "/build/Target-OutputFileMap.json")
        let objectDependencies = URL(filePath: "/build/A.d")
        let moduleDependencies = URL(filePath: "/build/Target-module.d")
        let generated = "/build/Generated.swift"
        let data = try json(["commands": [
            "swift": ["tool": "swift-driver-compilation", "inputs": [map.path, generated], "outputs": ["/build/A.o"]],
            "generated": ["tool": "auxiliary-file", "outputs": [generated]]
        ]])
        let mapData = try json(["/user/A.swift": ["object": "/build/A.o", "dependencies": objectDependencies.path],
            "": ["emit-module-dependencies": moduleDependencies.path]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, map: mapData,
            objectDependencies: Data("/build/A.o: /user/A.swift /user/Bridge\\ Header.h /user/Leaf.h /build/Generated.swift\n".utf8),
            moduleDependencies: Data("/build/Target.swiftmodule: /user/ModuleOnly.h\n".utf8)
        ]))
        #expect(files == Set(["/user/A.swift", "/user/Bridge Header.h", "/user/Leaf.h", "/user/ModuleOnly.h"].map { URL(filePath: $0) }))
        #expect(files?.contains(map) == false)
        #expect(files?.contains(objectDependencies) == false)
        #expect(files?.contains(moduleDependencies) == false)
    }

    @Test func clangDeclaredDepfileAndNestedResponseFiles() throws {
        let dependency = URL(filePath: "/build/A.d")
        let outer = URL(filePath: "/user/Outer Flags.rsp")
        let inner = URL(filePath: "/user/Inner Flags.rsp")
        let data = try json(["commands": ["compile": ["tool": "shell", "inputs": ["/user/A.c"],
            "outputs": ["/build/A.o"], "args": ["clang", "-c", "@" + outer.path],
            "deps": [dependency.path], "deps-style": "makefile", "working-directory": "/project"]]])
        let files = NativePreviewBuildInputs.files(manifest: manifest, read: reader([
            manifest: data, dependency: Data("/build/A.o: local\\ header.h ../external\\ header.h\n".utf8),
            outer: Data("'@/user/Inner Flags.rsp' -DNUMBER=42".utf8), inner: Data("-DSECOND=1".utf8)
        ]))
        #expect(files == Set(["/user/A.c", "/project/local header.h", "/external header.h", outer.path, inner.path].map { URL(filePath: $0) }))
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
        let data = try json(["commands": ["link": ["tool": "shell", "inputs": [], "outputs": ["/build/App"],
            "deps": [dependency.path], "deps-style": "dependency-info"]]])
        var info = Data([0]); info.append(Data("ld64\0".utf8))
        info.append(0x10); info.append(Data("/user/libSupport.a\0".utf8))
        info.append(0x11); info.append(Data("/user/Optional.tbd\0".utf8))
        info.append(0x40); info.append(Data("/build/App\0".utf8))
        #expect(NativePreviewBuildInputs.files(manifest: manifest, read: reader([manifest: data, dependency: info]))
            == Set([URL(filePath: "/user/libSupport.a"), URL(filePath: "/user/Optional.tbd")]))
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
        #expect(gnu == Set([outer, newline, nonbreakingSpace]))
        let first = URL(filePath: "/custom/First File.rsp")
        let second = URL(filePath: "/custom/Second.rsp")
        let swift = NativePreviewBuildInputs.files(manifest: manifest,
            compilerCommands: [.init(arguments: ["@" + outer.path], workingDirectory: URL(filePath: "/custom"),
                responseFileSyntax: .swiftDriver)],
            read: reader([manifest: data, outer: Data("// @Ignored.rsp\n@'First File.rsp'\n-DVALUE=1\u{a0}@Second.rsp".utf8),
                first: Data(), second: Data()]))
        #expect(swift == Set([outer, first, second]))
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
}
