import Foundation

package struct NativeXcodeInstallation: Sendable {
    package let developerDirectory: URL
    package let contentsDirectory: URL

    package init(developerDirectory: URL) throws {
        let directory = developerDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let contents = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: contents.appendingPathComponent("Frameworks/IDEFoundation.framework").path) else {
            throw NativeRuntimeError.unavailable("Selected developer directory does not contain Xcode IDEFoundation: \(directory.path)")
        }
        self.developerDirectory = directory
        self.contentsDirectory = contents
    }

    package func framework(_ name: String, in directory: String = "Frameworks") -> URL {
        contentsDirectory.appendingPathComponent("\(directory)/\(name).framework/Versions/A/\(name)")
    }

    package func launchEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["DEVELOPER_DIR"] = developerDirectory.path
        let frameworks = ["SharedFrameworks", "Frameworks", "PlugIns"].map {
            contentsDirectory.appendingPathComponent($0).path
        }
        let libraries = [contentsDirectory.path, contentsDirectory.appendingPathComponent("SharedFrameworks").path]
        for (key, paths) in [("DYLD_FRAMEWORK_PATH", frameworks), ("DYLD_LIBRARY_PATH", libraries)] {
            let inherited = environment[key].map { $0.split(separator: ":").map(String.init) } ?? []
            var seen = Set<String>()
            environment[key] = (paths + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        }
        return environment
    }
}
