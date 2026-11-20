import ABIBridge
import Foundation

/// Stages preview products into renderer applications: target selection, framework dependencies, static linking, and bundle assembly.
@MainActor
enum NativePreviewStaging {
    static func removeStagedApp(_ app: URL) throws {
        try FileManager.default.removeItem(at: app)
        let products = app.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
        if FileManager.default.fileExists(atPath: products.path) { try FileManager.default.removeItem(at: products) }
    }

    struct Selection {
        let source: NativePreviewBuild.Target
        let host: NativePreviewBuild.Target
    }

    static func selectTarget(_ targets: [NativePreviewBuild.Target], source: URL, platform: NativePreviewPlatform) throws -> Selection {
        let sourcePath = source.resolvingSymlinksInPath().path
        guard targets.contains(where: { $0.sourceFiles.contains { $0.resolvingSymlinksInPath().path == sourcePath } }) else {
            throw NativeRuntimeError.invalidRequest("The active scheme did not build \(source.path)")
        }
        let platformTargets = targets.filter {
            NativePreviewPlatform(sdkRoot: $0.sdkRoot, sdkVariant: $0.sdkVariant) == platform
        }
        let sources = platformTargets.filter {
            $0.architecture == "arm64" && $0.sourceFiles.contains { $0.resolvingSymlinksInPath().path == sourcePath }
        }
        guard !sources.isEmpty else { throw NativePipelineRequired() }
        var selections: [Selection] = []
        for target in sources {
            if let output = target.outputURL, productBundle(containing: output) != nil {
                selections.append(Selection(source: target, host: target))
                continue
            }
            let objectPaths = Set(target.objectFiles.map { $0.resolvingSymlinksInPath().path })
            let sourceOutput = target.outputURL
            let frameworkName = sourceOutput?.pathComponents.last(where: { $0.hasSuffix(".framework") })
            let hosts = try platformTargets.filter { candidate in
                guard candidate.architecture == "arm64",
                      let output = candidate.outputURL, let app = productBundle(containing: output) else { return false }
                if candidate.objectFiles.contains(where: { objectPaths.contains($0.resolvingSymlinksInPath().path) }) {
                    return true
                }
                guard let sourceOutput else { return false }
                if try (["a", "o", "dylib"].contains(sourceOutput.pathExtension)
                    || (frameworkName != nil && NativePreviewBinary.isStaticArchive(at: sourceOutput)))
                    && candidate.linksProduct(at: sourceOutput) { return true }
                guard frameworkName != nil || sourceOutput.pathExtension == "dylib" else { return false }
                let rootLibrary = app.appendingPathComponent(sourceOutput.lastPathComponent)
                if frameworkName == nil, FileManager.default.fileExists(atPath: rootLibrary.path),
                   try NativePreviewBinary.matches(sourceOutput, rootLibrary) {
                    return true
                }
                let frameworks = Bundle(url: app)?.privateFrameworksURL ?? app.appendingPathComponent("Frameworks", isDirectory: true)
                guard FileManager.default.fileExists(atPath: frameworks.path) else { return false }
                return try FileManager.default.subpathsOfDirectory(atPath: frameworks.path).contains { subpath in
                    let library = frameworks.appendingPathComponent(subpath)
                    guard library.lastPathComponent == sourceOutput.lastPathComponent,
                          frameworkName.map({ library.pathComponents.contains($0) }) ?? true else { return false }
                    return try NativePreviewBinary.matches(sourceOutput, library)
                }
            }
            selections += hosts.map { Selection(source: target, host: $0) }
            if hosts.isEmpty, let sourceOutput,
               try NativePreviewBinary.isStaticLibrary(at: sourceOutput)
                || (frameworkBundle(containing: sourceOutput) != nil && NativePreviewBinary.isDynamicLibrary(at: sourceOutput)) {
                selections.append(Selection(source: target, host: target))
            }
        }
        var candidates = selections
        let runnable = candidates.filter { $0.host.isRunnable }
        if !runnable.isEmpty { candidates = runnable }
        guard candidates.count == 1 else { throw NativePipelineRequired() }
        return candidates[0]
    }

    static func productBundle(containing output: URL) -> URL? {
        var url = output.deletingLastPathComponent()
        while url.path != "/" {
            if ["app", "appex"].contains(url.pathExtension) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func frameworkBundle(containing output: URL) -> URL? {
        var url = output.deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "framework" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func containingApp(for extensionOutput: URL, targets: [NativePreviewBuild.Target]) throws -> URL? {
        guard let product = productBundle(containing: extensionOutput), product.pathExtension == "appex" else { return nil }
        let relativeBinary = String(extensionOutput.path.dropFirst(product.path.count + 1))
        let candidates = try targets.compactMap { target -> (app: URL, isRunnable: Bool)? in
            guard target.architecture == "arm64", NativePreviewPlatform(sdkRoot: target.sdkRoot, sdkVariant: target.sdkVariant) != nil,
                  let output = target.outputURL, let app = productBundle(containing: output),
                  app.pathExtension == "app" else { return nil }
            let embedded = (Bundle(url: app)?.builtInPlugInsURL ?? app.appendingPathComponent("PlugIns", isDirectory: true))
                .appendingPathComponent(product.lastPathComponent, isDirectory: true)
                .appendingPathComponent(relativeBinary)
            guard FileManager.default.fileExists(atPath: embedded.path),
                  try NativePreviewBinary.matches(extensionOutput, embedded) else { return nil }
            return (app, target.isRunnable)
        }
        guard !candidates.isEmpty else { return nil }
        let runnable = candidates.filter(\.isRunnable)
        let matches = runnable.isEmpty ? candidates : runnable
        guard matches.count == 1 else { throw NativePipelineRequired() }
        return matches[0].app
    }

    static func widgetExtensionIdentifier(_ product: URL) throws -> String? {
        guard product.pathExtension == "appex" else { return nil }
        let info = try bundleInfo(at: product)
        guard (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension" else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    struct LinkedPreviewImage {
        let url: URL
        let searchPaths: [(framework: Bool, url: URL)]
        let linkInputs: [URL]
    }

    struct FrameworkDependencies {
        struct Relocation {
            let library: String
            let name: String
            let replacement: String
        }
        var products: [URL: String] = [:]
        var relocations: [Relocation] = []
        var rootLibraries: [String] = []
    }

    static func frameworkDependencies(for roots: [NativePreviewBuild.Target], targets: [NativePreviewBuild.Target],
                                      platform: NativePreviewPlatform, in products: URL, agentApp: URL? = nil,
                                      sourceProduct: URL? = nil, linkedImages: [URL: LinkedPreviewImage] = [:],
                                      environment: [String: String] = [:], nativeApp: URL? = nil) throws -> FrameworkDependencies {
        typealias SearchPath = (framework: Bool, url: URL)
        typealias Library = (output: URL, product: URL, identifier: String, dependencies: [String], rpaths: [String], target: NativePreviewBuild.Target?)
        let rootOutputs = Set(roots.compactMap { $0.outputURL?.resolvingSymlinksInPath() })
        func linkedImage(at output: URL) -> LinkedPreviewImage? {
            linkedImages.values.first { $0.url.resolvingSymlinksInPath() == output.resolvingSymlinksInPath() }
        }
        let nativeImage = roots.compactMap { root in
            root.outputURL.flatMap { linkedImages[$0.resolvingSymlinksInPath()]?.url }
        }.first
        func library(at output: URL, target: NativePreviewBuild.Target? = nil) throws -> Library? {
            let output = output.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard unsafe FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let image = try NativePreviewBinary.dynamicLibrary(at: output) else { return nil }
            let packageImage = nativeApp == nil && agentApp != nil && target?.isDynamicPackageProduct == true
                && rootOutputs.contains(output)
            let product = packageImage ? output : frameworkBundle(containing: output) ?? output
            return (output, product, image.identifier, image.dependencies, image.rpaths, target)
        }
        func relativePath(from directory: URL, to item: URL) -> String {
            let base = directory.standardizedFileURL.pathComponents
            let target = item.standardizedFileURL.pathComponents
            let shared = zip(base, target).prefix { $0.0 == $0.1 }.count
            return (Array(repeating: "..", count: base.count - shared) + target.dropFirst(shared)).joined(separator: "/")
        }
        func runtimeURL(_ path: String, importer: URL) -> URL? {
            if path == "@loader_path" { return importer.deletingLastPathComponent() }
            if path.hasPrefix("@loader_path/") {
                return importer.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst("@loader_path/".count)))
            }
            if nativeApp != nil, let output = nativeImage, let host = productBundle(containing: output) {
                let executable = platform.executableDirectory(in: host)
                if path == "@executable_path" { return executable }
                if path.hasPrefix("@executable_path/") {
                    return executable.appendingPathComponent(String(path.dropFirst("@executable_path/".count)))
                }
            }
            return path.hasPrefix("/") ? URL(filePath: path) : nil
        }
        func nativePath(_ url: URL) throws -> String? {
            guard let nativeApp else { return nil }
            var relationship: FileManager.URLRelationship = .other
            try unsafe FileManager.default.getRelationship(&relationship, ofDirectoryAt: nativeApp, toItemAt: url)
            guard relationship == .contains else { return nil }
            return url.resolvingSymlinksInPath().pathComponents
                .dropFirst(nativeApp.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
        }
        // Native-preloaded runtimes must keep their original image identity when their clients are relocated.
        let preloaded = Set(environment["DYLD_INSERT_LIBRARIES", default: ""].split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { URL(filePath: String($0)).resolvingSymlinksInPath() })
        let libraries = try targets.compactMap { target -> Library? in
            guard target.architecture == "arm64",
                  NativePreviewPlatform(sdkRoot: target.sdkRoot, sdkVariant: target.sdkVariant) == platform,
                  let output = target.outputURL, productBundle(containing: output) == nil else { return nil }
            return try library(at: linkedImages[output.resolvingSymlinksInPath()]?.url ?? output, target: target)
        }
        let rootImages = try roots.compactMap { root -> Library? in
            guard let output = root.outputURL?.resolvingSymlinksInPath() else { return nil }
            return try library(at: linkedImages[output]?.url ?? output, target: root)
        }
        var pending = try rootImages.map { root in
            let executable = nativeApp == nil ? nil : productBundle(containing: root.output).flatMap { Bundle(url: $0)?.executableURL }
            let executablePaths = try executable.flatMap { executable in
                try NativePreviewBinary.file(at: executable)?.rpaths.compactMap { runtimeURL($0, importer: executable) }
            } ?? []
            return (library: root, inheritedPaths: executablePaths, inheritedLinkPaths: [SearchPath]())
        }
        var visited = Set(rootImages.map { $0.output })
        var result = FrameworkDependencies()
        func stagedPath(_ library: Library) throws -> String {
            if let path = try nativePath(library.output) { return path }
            if linkedImage(at: library.output) != nil {
                return relativePath(from: products, to: library.output)
            }
            let product = library.product.resolvingSymlinksInPath()
            let relativeProduct: String
            if product == sourceProduct?.resolvingSymlinksInPath() {
                relativeProduct = product.lastPathComponent
            } else if let path = result.products[product] {
                relativeProduct = path
            } else {
                if nativeApp == nil, let agentApp, library.target?.isDynamicPackageProduct == true,
                   rootOutputs.contains(library.output) {
                    // Native package JIT images keep their dynamic boundary while their classes belong to the agent bundle.
                    let image = platform.executableDirectory(in: agentApp)
                        .appendingPathComponent("XcodeMCPPreviewPackage-\(UUID().uuidString).dylib")
                    relativeProduct = relativePath(from: products, to: image)
                } else {
                    let prefix = nativeApp.map { app in
                        let frameworks = platform.frameworksDirectory(in: app)
                        return frameworks.pathComponents.dropFirst(app.pathComponents.count).joined(separator: "/") + "/PreviewDependencies"
                    } ?? "Dependencies"
                    relativeProduct = "\(prefix)/\(result.products.count)/" + product.lastPathComponent
                }
                result.products[product] = relativeProduct
            }
            return relativeProduct + library.output.path.dropFirst(product.path.count)
        }
        result.rootLibraries = try rootImages.map { try stagedPath($0) }
        while let current = pending.popLast() {
            let runtimePaths = current.library.rpaths.compactMap { runtimeURL($0, importer: current.library.output) }
                + current.inheritedPaths
            let inputs = try current.library.target?.linkedInputs()
            let linkedImage = linkedImage(at: current.library.output)
            let searchPaths = (linkedImage?.searchPaths ?? inputs?.searchPaths ?? []) + current.inheritedLinkPaths
            let linkedLibraries = try (linkedImage?.linkInputs ?? inputs?.files ?? []).compactMap { candidate in
                try libraries.first { $0.output.resolvingSymlinksInPath() == candidate.resolvingSymlinksInPath() }
                    ?? library(at: candidate)
            }
            for name in current.library.dependencies {
                let matches = libraries.filter { $0.identifier == name || $0.output.path == name }
                var dependency: Library?
                var resolvedInNativeApp = false
                // Existing native products keep their packaging and loader paths. Only newly reachable code is staged.
                if nativeApp != nil {
                    let candidates = name.hasPrefix("@rpath/")
                        ? runtimePaths.map { $0.appendingPathComponent(String(name.dropFirst("@rpath/".count))) }
                        : runtimeURL(name, importer: current.library.output).map { [$0] } ?? []
                    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                        if try nativePath(candidate) != nil, let resolved = try library(at: candidate) {
                            dependency = resolved
                            resolvedInNativeApp = name.hasPrefix("@")
                            break
                        }
                    }
                }
                if dependency == nil { dependency = matches.first { $0.output.path == name } }
                if dependency == nil {
                    let linked = linkedLibraries.filter { $0.identifier == name || $0.output.path == name }
                    if linked.count == 1 { dependency = linked[0] }
                }
                if dependency == nil {
                    let candidates: [URL]
                    if name.hasPrefix("@rpath/") {
                        let relative = String(name.dropFirst("@rpath/".count))
                        let paths = searchPaths.filter { $0.framework == relative.contains(".framework/") }.map(\.url)
                        candidates = (runtimePaths + paths).map { $0.appendingPathComponent(relative) }
                    } else {
                        candidates = runtimeURL(name, importer: current.library.output).map { [$0] } ?? []
                    }
                    // Prebuilt inputs have no native target record; their real load commands and linker paths locate them.
                    for candidate in candidates {
                        if let built = libraries.first(where: { $0.output.resolvingSymlinksInPath() == candidate.resolvingSymlinksInPath() }) {
                            dependency = built
                            break
                        }
                        if let resolved = try library(at: candidate) {
                            dependency = resolved
                            break
                        }
                    }
                }
                if dependency == nil, matches.count == 1 { dependency = matches[0] }
                guard let dependency, !preloaded.contains(dependency.output) else { continue }
                let importer = try stagedPath(current.library)
                let target = try stagedPath(dependency)
                let replacement = "@loader_path/" + relativePath(
                    from: products.appendingPathComponent(importer).deletingLastPathComponent(),
                    to: products.appendingPathComponent(target))
                let internalRelative = name.hasPrefix("@loader_path/")
                    && current.library.product.resolvingSymlinksInPath() == dependency.product.resolvingSymlinksInPath()
                if name != replacement && !internalRelative && !resolvedInNativeApp {
                    result.relocations.append(.init(library: importer, name: name,
                        replacement: replacement))
                }
                if visited.insert(dependency.output.resolvingSymlinksInPath()).inserted {
                    pending.append((dependency, runtimePaths, searchPaths))
                }
            }
        }
        return result
    }

    static func linkStaticProducts(for roots: [NativePreviewBuild.Target], host: NativePreviewBuild.Target? = nil,
                                   in app: URL, products: URL, platform: NativePreviewPlatform,
                                   process: NativePreviewProcess) async throws -> [URL: LinkedPreviewImage] {
        let staticRoots = try roots.filter { root in
            try root.outputURL.map { try NativePreviewBinary.isStaticLibrary(at: $0) } ?? false
        }
        let staticOutputs = Set(staticRoots.compactMap { $0.outputURL?.resolvingSymlinksInPath() })
        var images: [URL: LinkedPreviewImage] = [:]
        var active: Set<URL> = []
        func link(_ root: NativePreviewBuild.Target) async throws {
            guard let output = root.outputURL?.resolvingSymlinksInPath(), images[output] == nil else { return }
            guard active.insert(output).inserted else {
                throw NativeRuntimeError.unsupportedContract("The static preview roots contain a link dependency cycle at \(root.buildableName)")
            }
            defer { active.remove(output) }
            if staticOutputs.count > 1 {
                for dependency in root.dependencies {
                    if let peer = staticRoots.first(where: { $0.outputURL?.resolvingSymlinksInPath() == dependency.outputURL?.resolvingSymlinksInPath() }) {
                        try await link(peer)
                    }
                }
                let targets = [root] + root.dependencies.filter { dependency in
                    dependency.outputURL.map { !staticOutputs.contains($0.resolvingSymlinksInPath()) } ?? true
                }
                for target in targets {
                    guard let targetOutput = target.outputURL?.resolvingSymlinksInPath(),
                          try NativePreviewBinary.isStaticLibrary(at: targetOutput) else { continue }
                    for input in try target.linkedInputs().files where input.resolvingSymlinksInPath() != targetOutput {
                        if let peer = staticRoots.first(where: { $0.outputURL?.resolvingSymlinksInPath() == input.resolvingSymlinksInPath() }) {
                            try await link(peer)
                        }
                    }
                }
            }
            let packageRoot = host == nil && root.isDynamicPackageProduct
            let directory = packageRoot ? platform.executableDirectory(in: app) : products
            let name = packageRoot ? "XcodeMCPPreviewPackage-\(UUID().uuidString).dylib"
                : staticRoots.count == 1 ? "XcodeMCPPreviewSource.dylib" : "XcodeMCPPreviewSource-\(UUID().uuidString).dylib"
            images[output] = try await linkStaticProduct(root, host: host, in: app, products: products,
                to: directory.appendingPathComponent(name), linkedImages: images, platform: platform, process: process)
        }
        for root in staticRoots { try await link(root) }
        return images
    }

    static func linkStaticProduct(_ source: NativePreviewBuild.Target, host: NativePreviewBuild.Target? = nil,
                                    in app: URL, products: URL, to image: URL? = nil,
                                    linkedImages: [URL: LinkedPreviewImage] = [:], platform: NativePreviewPlatform,
                                    process: NativePreviewProcess) async throws -> LinkedPreviewImage {
        guard let output = source.outputURL else {
            throw NativeRuntimeError.unsupportedContract("The static preview target has no linked product")
        }
        let image = image ?? products.appendingPathComponent("XcodeMCPPreviewSource.dylib")
        if let host, host.outputURL?.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() {
            return try await linkStaticProduct(source, host: host, to: image, in: app.deletingLastPathComponent(),
                installName: "@rpath/" + image.lastPathComponent, process: process)
        }
        // A separate image keeps the static source's entry symbol away from the renderer's entry point.
        // Its placement preserves the bundle owner selected for this native root.
        let archive = try NativePreviewBinary.isStaticArchive(at: output)
        let input = app.deletingLastPathComponent().appendingPathComponent(image.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(archive ? "a" : "o")
        try copyReplacingItem(output, to: input)
        let sdk = try await process.xcrun(["--sdk", platform.sdk, "--show-sdk-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A Swift input supplies runtime libraries without recompiling the source product.
        let linkSource = app.deletingLastPathComponent().appendingPathComponent("PreviewSource.swift")
        try Data().write(to: linkSource)
        var arguments = ["--sdk", platform.sdk, "swiftc", "-emit-library", "-parse-as-library", "-target", platform.triple, "-sdk", sdk,
            linkSource.path, "-lc++"]
        arguments += archive ? ["-Xlinker", "-force_load", "-Xlinker", input.path] : [input.path]
        arguments += [
            "-Xlinker", "-headerpad_max_install_names", "-Xlinker", "-install_name", "-Xlinker",
            "@rpath/" + image.lastPathComponent, "-o", image.path]
        let targets = [source] + source.dependencies.filter { dependency in
            dependency.outputURL.flatMap { linkedImages[$0.resolvingSymlinksInPath()] } == nil
        }
        let sanitizers = [(targets.contains(where: \.enableAddressSanitizer), "address"),
                          (targets.contains(where: \.enableThreadSanitizer), "thread"),
                          (targets.contains(where: \.enableUndefinedBehaviorSanitizer), "undefined")].filter(\.0).map(\.1)
        if !sanitizers.isEmpty { arguments.append("-sanitize=" + sanitizers.joined(separator: ",")) }
        let inputs = try targets.map { try $0.linkedInputs() }
        let outputs = Set(targets.compactMap { $0.outputURL?.resolvingSymlinksInPath() })
        var merged: Set<URL> = []
        for (target, inputs) in zip(targets, inputs) {
            guard let targetOutput = target.outputURL else { continue }
            let mergesArchives = try NativePreviewBinary.isStaticArchive(at: targetOutput)
            guard try mergesArchives || NativePreviewBinary.file(at: targetOutput)?.header.fileType == .object else { continue }
            for input in inputs.files {
                let path = input.resolvingSymlinksInPath()
                guard path != targetOutput.resolvingSymlinksInPath(), outputs.contains(path) else { continue }
                // Relocatable links consume object inputs, but may leave archive members for the final link.
                let fullyMerged = try mergesArchives ? NativePreviewBinary.isStaticLibrary(at: input)
                    : NativePreviewBinary.file(at: input)?.header.fileType == .object
                if fullyMerged { merged.insert(path) }
            }
        }
        var linked = merged.union([output.resolvingSymlinksInPath()])
        for dependency in source.dependencies {
            guard let output = dependency.outputURL else {
                throw NativeRuntimeError.unsupportedContract("The preview dependency \(dependency.buildableName) has no linked product")
            }
            guard linked.insert(output.resolvingSymlinksInPath()).inserted else { continue }
            let input = linkedImages[output.resolvingSymlinksInPath()]?.url ?? output
            arguments += try NativePreviewBinary.file(at: input)?.header.fileType == .object
                ? [input.path] : ["-Xlinker", input.path]
        }
        for (target, inputs) in zip(targets, inputs) {
            guard let output = target.outputURL, try NativePreviewBinary.isStaticLibrary(at: output) else { continue }
            for path in target.searchPaths(in: target.compileCommandLine) + target.searchPaths(in: target.linkCommandLine) {
                arguments += [path.argument, path.url.path]
            }
            for input in inputs.files where !linked.contains(input.resolvingSymlinksInPath()) {
                let linkedInput = linkedImages[input.resolvingSymlinksInPath()]?.url ?? input
                var directory: ObjCBool = false
                if unsafe FileManager.default.fileExists(atPath: linkedInput.path, isDirectory: &directory), !directory.boolValue,
                   try linkedInput.pathExtension == "tbd" || NativePreviewBinary.isStaticArchive(at: linkedInput) || NativePreviewBinary.isDynamicLibrary(at: linkedInput) {
                    arguments += ["-Xlinker", linkedInput.path]
                    linked.insert(input.resolvingSymlinksInPath())
                }
            }
            for library in inputs.libraries where library.file == nil {
                arguments += library.framework ? ["-framework", library.name] : ["-l" + library.name]
            }
        }
        let command = ["/usr/bin/xcrun"] + arguments
        _ = try await process.xcrun(arguments)
        // Native debug links can defer code signing to Xcode; this generated copy has its own signing owner.
        _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", image.path])
        if let framework = frameworkBundle(containing: output) {
            let copiedFramework = products.appendingPathComponent(framework.lastPathComponent)
            if FileManager.default.fileExists(atPath: copiedFramework.path) {
                _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", copiedFramework.path])
            }
        }
        let linkedInputs = try source.linkedInputs(in: command)
        return LinkedPreviewImage(url: image, searchPaths: linkedInputs.searchPaths, linkInputs: linkedInputs.files)
    }

    private static func linkStaticProduct(_ source: NativePreviewBuild.Target, host: NativePreviewBuild.Target,
                                           to image: URL, in directory: URL, installName: String? = nil,
                                           process: NativePreviewProcess) async throws -> LinkedPreviewImage {
        guard let output = source.outputURL else {
            throw NativeRuntimeError.unsupportedContract("The static preview target has no linked product")
        }
        let input = directory.appendingPathComponent(try NativePreviewBinary.isStaticArchive(at: output)
            ? "PreviewSource.a" : output.lastPathComponent)
        try copyReplacingItem(output, to: input)
        let command = try hostedStaticProductCommand(source: source, host: host, product: input, image: image,
            installName: installName)
        _ = try await process.run(command[0], Array(command.dropFirst()),
            directory: host.linkerWorkingDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) })
        _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", image.path])
        let inputs = try host.linkedInputs(in: command)
        return LinkedPreviewImage(url: image, searchPaths: inputs.searchPaths, linkInputs: inputs.files)
    }

    static func prepareNativeExtension(source: NativePreviewBuild.Target, host: NativePreviewBuild.Target,
                                       containingApp: URL, in directory: URL, targets: [NativePreviewBuild.Target],
                                       platform: NativePreviewPlatform, process: NativePreviewProcess) async throws -> URL {
        guard let output = host.outputURL, let product = productBundle(containing: output) else {
            throw NativeRuntimeError.unsupportedContract("The static preview host has no linked product")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = directory.appendingPathComponent(containingApp.lastPathComponent, isDirectory: true)
        try copyReplacingItem(containingApp, to: app)
        let originalEmbedded = (Bundle(url: containingApp)?.builtInPlugInsURL ?? containingApp.appendingPathComponent("PlugIns", isDirectory: true))
            .appendingPathComponent(product.lastPathComponent, isDirectory: true)
        let embedded = app.appendingPathComponent(originalEmbedded.pathComponents.dropFirst(containingApp.pathComponents.count)
            .joined(separator: "/"), isDirectory: true)
        let image = embedded.appendingPathComponent(output.pathComponents.dropFirst(product.pathComponents.count).joined(separator: "/"))
        let linked = try await linkStaticProduct(source, host: host, to: image, in: directory, process: process)
        let dependencies = try frameworkDependencies(for: [source], targets: targets, platform: platform,
            in: app, linkedImages: source.outputURL.map { [$0.resolvingSymlinksInPath(): linked] } ?? [:],
            environment: host.rendererEnvironment, nativeApp: app)
        try copyFrameworkDependencies(dependencies, into: app)
        try await relocateFrameworkDependencies(dependencies, in: app, process: process)
        // Re-sign only the changed owners, preserving each bundle's own entitlements and executable stub.
        for (original, copy) in [(originalEmbedded, embedded), (containingApp, app)] {
            var signing = ["--force", "--sign", "-"]
            if let entitlements = try NativePreviewEntitlements.read(from: original).signed {
                let plist = directory.appendingPathComponent(copy.lastPathComponent + "-entitlements.plist")
                try entitlements.write(to: plist)
                signing += ["--entitlements", plist.path]
            }
            _ = try await process.run("/usr/bin/codesign", signing + [copy.path])
        }
        return app
    }

    private static func hostedStaticProductCommand(source: NativePreviewBuild.Target, host: NativePreviewBuild.Target,
                                                       product: URL, image: URL, installName: String?) throws -> [String] {
        guard let executable = host.linkCommandLine.first else {
            throw NativeRuntimeError.unsupportedContract("The static preview host has no link command")
        }
        let directory = product.deletingLastPathComponent().appendingPathComponent("PreviewLink", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputs = try host.linkedInputs()
        let mergesArchives = try NativePreviewBinary.isStaticArchive(at: product)
        var owned = Set((source.objectFiles + [source.outputURL].compactMap { $0 }).map { $0.resolvingSymlinksInPath() })
        // A relocatable link can leave archive members for the host's final link.
        for input in try source.linkedInputs().files {
            var isDirectory: ObjCBool = false
            if unsafe FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               try (mergesArchives && NativePreviewBinary.isStaticArchive(at: input))
                || NativePreviewBinary.file(at: input)?.header.fileType == .object {
                owned.insert(input.resolvingSymlinksInPath())
            }
        }
        func owns(_ path: String) -> Bool {
            host.url(for: path).map { owned.contains($0.resolvingSymlinksInPath()) } ?? false
        }
        func ownsLibrary(framework: Bool, name: String) -> Bool {
            inputs.libraries.contains { $0.framework == framework && $0.name == name
                && $0.file.map { owned.contains($0.resolvingSymlinksInPath()) } == true }
        }
        func encode(_ argument: (value: String, forwarded: Bool), replacing value: String? = nil) -> [String] {
            let value = value ?? argument.value
            return argument.forwarded ? ["-Xlinker", value] : [value]
        }
        let arguments = host.linkArguments(in: Array(host.linkCommandLine.dropFirst()))
        var result = [executable]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            if ["-o", "-install_name", "-dependency_info", "-object_path_lto", "-map"].contains(argument.value), let next {
                let value = argument.value == "-o" ? image.path : argument.value == "-install_name" ? installName ?? next.value
                    : directory.appendingPathComponent(URL(filePath: next.value).lastPathComponent).path
                result += encode(argument) + encode(next, replacing: value)
                index += 2
            } else if argument.value == "-filelist", let next, let path = host.url(for: next.value) {
                let entries = try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
                let copy = directory.appendingPathComponent("PreviewLinkFileList-\(index).txt")
                try (entries.filter { !owns($0) }.joined(separator: "\n") + "\n").write(to: copy, atomically: true, encoding: .utf8)
                result += encode(argument) + encode(next, replacing: copy.path)
                index += 2
            } else if argument.value == "-force_load", let next, owns(next.value) {
                index += 2
            } else if argument.value == "-framework", let next, ownsLibrary(framework: true, name: next.value) {
                index += 2
            } else if argument.value == "-l", let next, ownsLibrary(framework: false, name: next.value) {
                index += 2
            } else if argument.value.hasPrefix("-l"), ownsLibrary(framework: false, name: String(argument.value.dropFirst(2))) {
                index += 1
            } else {
                if !owns(argument.value) { result += encode(argument) }
                index += 1
            }
        }
        for path in source.searchPaths(in: source.compileCommandLine) + source.searchPaths(in: source.linkCommandLine) {
            result += [path.argument == "-L" ? "-L" : "-F", path.url.path]
        }
        let sourceArguments = mergesArchives
            ? ["-Xlinker", "-force_load", "-Xlinker", product.path] : [product.path]
        return result + sourceArguments + ["-Xlinker", "-headerpad_max_install_names"]
    }

    static func copyFrameworkDependencies(_ dependencies: FrameworkDependencies, into products: URL) throws {
        for (source, path) in dependencies.products {
            let destination = products.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func relocateFrameworkDependencies(_ dependencies: FrameworkDependencies, in products: URL,
                                             process: NativePreviewProcess) async throws {
        var changedFrameworks: Set<URL> = []
        for path in Set(dependencies.relocations.map(\.library)).sorted() {
            let library = products.appendingPathComponent(path).standardizedFileURL
            let arguments = dependencies.relocations.filter { $0.library == path }.flatMap { ["-change", $0.name, $0.replacement] }
            _ = try await process.xcrun(["install_name_tool"] + arguments + [library.path])
            _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", library.path])
            if let framework = frameworkBundle(containing: library) { changedFrameworks.insert(framework) }
        }
        // Nested dylibs can be sealed framework resources; refresh their owning bundle after re-signing the changed code.
        for framework in changedFrameworks.sorted(by: { $0.path.count > $1.path.count }) {
            _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", framework.path])
        }
    }

    @discardableResult
    static func prepareApp(product: URL, sourceProduct: URL? = nil, helper: URL, app: URL, containingApp: URL? = nil,
                           platform: NativePreviewPlatform = .iOS, clientIdentifier: String? = nil,
                           staticProduct: Bool = false, resourceURLs: [URL] = []) throws -> URL {
        let frameworks = platform.frameworksDirectory(in: app)
        let products: URL
        if let sourceProduct, staticProduct {
            products = app.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
                .appendingPathComponent(sourceProduct.deletingLastPathComponent().lastPathComponent, isDirectory: true)
        } else { products = frameworks }
        try FileManager.default.copyItem(at: product, to: app)
        let original = try bundleInfo(at: app)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        if let sourceProduct, sourceProduct.pathExtension == "framework" {
            try FileManager.default.copyItem(at: sourceProduct, to: products.appendingPathComponent(sourceProduct.lastPathComponent))
        }
        for resource in resourceURLs {
            try FileManager.default.copyItem(at: resource, to: products.appendingPathComponent(resource.lastPathComponent))
        }
        let executable = helper.appendingPathComponent("XcodeMCPPreviewRenderer")
        try copyReplacingItem(executable, to: platform.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer"))
        var info = Self.rendererInfo(original, platform: platform)
        // The client coexists with the original extension registration.
        if let clientIdentifier { info["CFBundleIdentifier"] = clientIdentifier }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: platform.infoURL(in: app))
        try FileManager.default.createDirectory(at: platform.resourcesDirectory(in: app), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if let shared = containingApp.map({ platform.frameworksDirectory(in: $0) }),
           FileManager.default.fileExists(atPath: shared.path) {
            // Extensions search their own Frameworks before their containing app's.
            for item in try FileManager.default.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil) {
                let destination = frameworks.appendingPathComponent(item.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: item, to: destination)
                }
            }
        }
        try copyContents(helper.appendingPathComponent("Frameworks"), to: frameworks)
        return products
    }

    static func appName(product: URL, containingApp: URL?, localization: String?) throws -> String {
        let owner = containingApp ?? product
        guard let bundle = Bundle(url: owner) else { throw NativePipelineRequired() }
        if let localization {
            let info = bundle.infoDictionary ?? [:]
            let key = info["CFBundleDisplayName"] is String ? "CFBundleDisplayName" : "CFBundleName"
            guard let name = info[key] as? String else { return "" }
            return bundle.localizedString(forKey: key, value: name, table: "InfoPlist",
                localizations: [Locale.Language(identifier: localization)])
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    }

    static func rendererInfo(_ original: [String: Any], platform: NativePreviewPlatform = .iOS) -> [String: Any] {
        let startupKeys = ["CFBundleExecutable", "CFBundlePackageType", "NSPrincipalClass", "UIMainStoryboardFile",
                           "UIApplicationSceneManifest", "NSExtension", "NSMainNibFile", "NSMainStoryboardFile",
                           "UISupportedInterfaceOrientations"]
        // Bundle lookup gives platform/device-qualified keys precedence over base keys.
        var info = original.filter { key, _ in
            !startupKeys.contains { key == $0 || key.hasPrefix($0 + "-") || key.hasPrefix($0 + "~") }
        }
        info["CFBundleExecutable"] = "XcodeMCPPreviewRenderer"
        info["CFBundlePackageType"] = "APPL"
        let minimumKey = platform.isSimulator ? "MinimumOSVersion" : "LSMinimumSystemVersion"
        if (info[minimumKey] as? String ?? "").compare(platform.minimumVersion, options: .numeric) == .orderedAscending {
            info[minimumKey] = platform.minimumVersion
        }
        if platform != .macOS && platform != .watchOS {
            info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                                        "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
            info["UIApplicationSceneManifest"] = ["UIApplicationSupportsMultipleScenes": false,
            "UISceneConfigurations": ["UIWindowSceneSessionRoleApplication": [["UISceneConfigurationName": "Preview", "UISceneDelegateClassName": "XcodeMCPPreviewRenderer.PreviewRendererScene"]]]]
        }
        if platform == .macOS { info["NSPrincipalClass"] = "NSApplication" }
        if platform == .watchOS {
            info["WKApplication"] = true
            info["WKWatchOnly"] = true
            info["WKRunsIndependentlyOfCompanionApp"] = nil
            info["WKCompanionAppBundleIdentifier"] = nil
        }
        return info
    }

    private static func copyContents(_ source: URL, to destination: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copyReplacingItem(item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    private static func copyReplacingItem(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func previewLibraries(in app: URL, platform: NativePreviewPlatform) throws -> [URL] {
        let libraries = try FileManager.default.contentsOfDirectory(at: platform.executableDirectory(in: app), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".debug.dylib") }
        guard !libraries.isEmpty else { throw NativePipelineRequired() }
        return libraries
    }

    static func programLibraries(previewLibraries: [URL], output: URL) throws -> [URL] {
        try previewLibraries.filter { try NativePreviewBinary.matches(output, $0) }
    }

    static func registryLibraries(in app: URL, previewLibraries: [URL], products: URL? = nil) throws -> [URL] {
        var libraries = previewLibraries
        libraries += try FileManager.default.contentsOfDirectory(at: Bundle(url: app)?.executableURL?.deletingLastPathComponent() ?? app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dylib" }
        let frameworks = Bundle(url: app)?.privateFrameworksURL ?? app.appendingPathComponent("Frameworks", isDirectory: true)
        for directory in Set([frameworks] + (products.map { [$0] } ?? [])) {
            for subpath in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
                let item = directory.appendingPathComponent(subpath)
                if item.pathExtension == "framework" {
                    if let executable = Bundle(url: item)?.executableURL { libraries.append(executable) }
                } else if item.pathExtension == "dylib" {
                    libraries.append(item)
                }
            }
        }
        return Array(Set(libraries.map { $0.resolvingSymlinksInPath() })).sorted { $0.path < $1.path }
    }

    static func libraryPaths(in app: URL, previewLibraries: [URL], registryLibraries: [URL], sourceOutput: URL?,
                             products: URL? = nil) throws -> [String] {
        var libraries = previewLibraries
        if let sourceOutput, Self.productBundle(containing: sourceOutput) == nil {
            let frameworkName = sourceOutput.pathComponents.last(where: { $0.hasSuffix(".framework") })
            if frameworkName != nil || sourceOutput.pathExtension == "dylib",
               try !NativePreviewBinary.isStaticArchive(at: sourceOutput) {
                guard let sourceLibrary = try registryLibraries.first(where: { library in
                    guard library.lastPathComponent == sourceOutput.lastPathComponent,
                          frameworkName.map({ library.pathComponents.contains($0) }) ?? true else { return false }
                    return try NativePreviewBinary.matches(sourceOutput, library)
                }) else { throw NativePipelineRequired() }
                libraries.append(sourceLibrary)
            }
        }
        let root = app.resolvingSymlinksInPath()
        let products = products?.resolvingSymlinksInPath()
        var paths: [String] = []
        for library in libraries {
            let library = library.resolvingSymlinksInPath()
            var relationship: FileManager.URLRelationship = .other
            try unsafe FileManager.default.getRelationship(&relationship, ofDirectoryAt: root, toItemAt: library)
            let relative: String
            if relationship == .contains {
                relative = String(library.path.dropFirst(root.path.count + 1))
            } else if let products {
                try unsafe FileManager.default.getRelationship(&relationship, ofDirectoryAt: products, toItemAt: library)
                guard relationship == .contains else { throw NativePipelineRequired() }
                let operation = root.deletingLastPathComponent()
                try unsafe FileManager.default.getRelationship(&relationship, ofDirectoryAt: operation, toItemAt: library)
                guard relationship == .contains else { throw NativePipelineRequired() }
                relative = "../" + library.path.dropFirst(operation.path.count + 1)
            } else { throw NativePipelineRequired() }
            if !paths.contains(relative) { paths.append(relative) }
        }
        return paths
    }

    static func registryNames(in symbols: String) -> [String] {
        Set(symbols.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let symbol = String(line)
            // Names may use mangling substitutions. The renderer checks PreviewRegistry conformance.
            guard symbol.hasPrefix("_$s"), symbol.hasSuffix("VMn"), symbol.contains("fMu_") else { return nil }
            return String(symbol.dropFirst(3).dropLast(2))
        }).sorted()
    }

    static func programRootNames(in symbols: String) -> [String] {
        let suffix = "5$mainyyFZ"
        return Set(symbols.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let symbol = String(line)
            // The renderer checks Widget/WidgetBundle conformance before initializing the program root.
            guard symbol.hasPrefix("_$s"), symbol.hasSuffix(suffix) else { return nil }
            return String(symbol.dropFirst(3).dropLast(suffix.count))
        }).sorted()
    }

    static func bundleInfo(at bundle: URL) throws -> [String: Any] {
        let rootInfo = bundle.appendingPathComponent("Info.plist")
        let infoURL = FileManager.default.fileExists(atPath: rootInfo.path) ? rootInfo : bundle.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("The built preview product has an unsupported Info.plist")
        }
        return info
    }
}
