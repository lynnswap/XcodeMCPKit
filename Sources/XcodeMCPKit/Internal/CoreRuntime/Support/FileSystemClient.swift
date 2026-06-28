import Foundation

package struct FileSystemClient: DependencyClient {
    package var fileExists: @Sendable (_ path: String) -> Bool
    package var regularFileExists: @Sendable (_ path: String) -> Bool
    package var directoryExists: @Sendable (_ path: String) -> Bool
    package var isExecutableFile: @Sendable (_ path: String) -> Bool
    package var enumeratedFileURLs: @Sendable (_ root: URL) -> AnySequence<URL>

    package init(
        fileExists: @escaping @Sendable (_ path: String) -> Bool,
        regularFileExists: @escaping @Sendable (_ path: String) -> Bool,
        directoryExists: @escaping @Sendable (_ path: String) -> Bool,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        enumeratedFileURLs: @escaping @Sendable (_ root: URL) -> AnySequence<URL>
    ) {
        self.fileExists = fileExists
        self.regularFileExists = regularFileExists
        self.directoryExists = directoryExists
        self.isExecutableFile = isExecutableFile
        self.enumeratedFileURLs = enumeratedFileURLs
    }

    package static let liveValue = Self(
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        regularFileExists: { path in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        },
        directoryExists: { path in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        },
        isExecutableFile: { path in
            FileManager.default.isExecutableFile(atPath: path)
        },
        enumeratedFileURLs: { root in
            AnySequence {
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil
                )
                return AnyIterator {
                    enumerator?.nextObject() as? URL
                }
            }
        }
    )

    package static let testValue = Self(
        fileExists: { _ in false },
        regularFileExists: { _ in false },
        directoryExists: { _ in false },
        isExecutableFile: { _ in false },
        enumeratedFileURLs: { _ in AnySequence([]) }
    )
}
