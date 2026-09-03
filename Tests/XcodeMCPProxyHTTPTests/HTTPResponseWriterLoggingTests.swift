import Foundation
import Logging
import NIOHTTP1
import Testing

@testable import XcodeMCPProxyHTTP

@Suite
struct HTTPResponseWriterLoggingTests {
    @Test func accessEventsUseDebugLevel() {
        let recorder = HTTPLogRecorder()
        let logger = Logger(label: "HTTPResponseWriterLoggingTests") { _ in
            RecordingHTTPLogHandler(recorder: recorder)
        }
        let writer = HTTPResponseWriter(logger: logger)
        let request = HTTPHandler.RequestLogContext(
            id: "request-id",
            method: "GET",
            path: "/mcp",
            remoteAddress: "::1:12345"
        )

        writer.logRequest(request)
        writer.logResponse(request, status: .notFound, sessionID: "session-id")

        #expect(
            recorder.records() == [
                HTTPLogRecord(level: .debug, message: "HTTP request"),
                HTTPLogRecord(level: .debug, message: "HTTP response"),
            ])
    }
}

private struct HTTPLogRecord: Equatable, Sendable {
    let level: Logger.Level
    let message: String
}

private final class HTTPLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HTTPLogRecord] = []

    func append(_ record: HTTPLogRecord) {
        lock.withLock { storage.append(record) }
    }

    func records() -> [HTTPLogRecord] {
        lock.withLock { storage }
    }
}

private struct RecordingHTTPLogHandler: LogHandler {
    let recorder: HTTPLogRecorder
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        recorder.append(HTTPLogRecord(level: level, message: message.description))
    }
}
