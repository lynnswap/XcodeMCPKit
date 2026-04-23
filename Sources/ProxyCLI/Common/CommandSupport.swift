import Foundation

package protocol CLICommandAdapter {
    func start() async
    func wait() async
}

package protocol ProxyServerCommandServer {
    func startAndWriteDiscovery() throws -> (host: String, port: Int)
    func wait() async throws
}

extension FileHandle {
    package static func writeLine(_ text: String, to handle: FileHandle) {
        let data = Data((text + "\n").utf8)
        handle.write(data)
    }
}
