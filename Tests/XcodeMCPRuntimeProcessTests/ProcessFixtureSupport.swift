import Darwin
import Foundation

struct TemporaryFIFO: Sendable {
    let path: String
    let reader: FIFOMessageReader
    let writer: FIFOMessageWriter

    private let directoryURL: URL

    init(name: String) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeMCPRuntimeProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let path = directoryURL.appendingPathComponent(name).path
        guard unsafe mkfifo(path, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }
        self.path = path
        self.reader = try FIFOMessageReader(path: path)
        self.writer = try FIFOMessageWriter(path: path)
        self.directoryURL = directoryURL
    }

    func cleanup() {
        reader.close()
        writer.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

final class FIFOMessageReader: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: CInt?

    init(path: String) throws {
        let fd = unsafe Darwin.open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw currentPOSIXError()
        }
        self.fd = fd
    }

    deinit {
        close()
    }

    func readLine() async throws -> String {
        let fd = try currentFileDescriptor()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try readFIFOMessageLine(from: fd)
            }.value
        } onCancel: {
            self.close()
        }
    }

    func close() {
        let fd = locked {
            defer {
                self.fd = nil
            }
            return self.fd
        }
        if let fd {
            Darwin.close(fd)
        }
    }

    private func currentFileDescriptor() throws -> CInt {
        try locked {
            guard let fd else {
                throw POSIXError(.EBADF)
            }
            return fd
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}

final class FIFOMessageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: CInt?

    init(path: String) throws {
        let fd = unsafe Darwin.open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw currentPOSIXError()
        }
        self.fd = fd
    }

    deinit {
        close()
    }

    func writeLine(_ line: String) throws {
        let fd = try currentFileDescriptor()
        try writeAll(Data((line + "\n").utf8), to: fd)
    }

    func close() {
        let fd = locked {
            defer {
                self.fd = nil
            }
            return self.fd
        }
        if let fd {
            Darwin.close(fd)
        }
    }

    private func currentFileDescriptor() throws -> CInt {
        try locked {
            guard let fd else {
                throw POSIXError(.EBADF)
            }
            return fd
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}

func parsePID(_ line: String) throws -> pid_t {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int32(trimmed) else {
        throw ProcessFixtureError.invalidPID(trimmed)
    }
    return pid_t(value)
}

func readFIFOMessageLine(from fd: CInt) throws -> String {
    var bytes: [UInt8] = []
    while true {
        var byte: UInt8 = 0
        let readCount = unsafe Darwin.read(fd, &byte, 1)
        if readCount == 1 {
            if byte == UInt8(ascii: "\n") {
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
            continue
        }
        if readCount == 0 {
            throw POSIXError(.EPIPE)
        }
        if errno == EINTR {
            continue
        }
        throw currentPOSIXError()
    }
}

func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func writeAll(_ data: Data, to fd: CInt) throws {
    var offset = 0
    while offset < data.count {
        let written = unsafe data.withUnsafeBytes { buffer in
            unsafe Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if written > 0 {
            offset += written
            continue
        }
        if written == -1, errno == EINTR {
            continue
        }
        throw currentPOSIXError()
    }
}

private enum ProcessFixtureError: Error {
    case invalidPID(String)
}
