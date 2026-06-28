import Foundation
import Logging

actor StdioWriter {
    private let handle: FileHandle
    private let logger: Logger

    init(handle: FileHandle, logger: Logger) {
        self.handle = handle
        self.logger = logger
    }

    func send(_ data: Data) {
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        handle.write(payload)
    }
}
