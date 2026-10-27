import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeCrashSyncStoreTests {
    @Test func boundedAcquisitionAndReaderCursorsReplayAfterReopeningTheStore() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(component: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let first = try writeLog(logs, name: nativeName(day: 1), text: "first sample")
        let second = try writeLog(logs, name: nativeName(day: 2), text: "second sample")
        let undated = try writeLog(logs, name: "undated.crash", text: "sample without an event date")
        let query = scope()
        let cache = root.appending(component: "Cache")
        let store = try NativeCrashSyncStore(root: cache)
        let imported = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 1, maxBytes: 1024 * 1024)
        #expect(try nativeTestField(imported, "cacheInfo", "processedCount") == .number(.int(1)))
        let originalCursor = try string(imported, "cursor")
        let continuation = try string(imported, "nextCursor")

        let gate = AsyncStream<Void>.makeStream()
        let cancelled = Task {
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return try await store.resumeSync(continuation)
        }
        cancelled.cancel()
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let reopened = try NativeCrashSyncStore(root: cache)
        #expect(try await reopened.resumeSync(originalCursor) == imported)
        await #expect(throws: NativeRuntimeError.self) {
            try await reopened.resumeSync(originalCursor, matching: .object(["max_records": .number(.int(2))]))
        }
        let resumed = try await reopened.resumeSync(continuation)
        #expect(try await reopened.resumeSync(continuation) == resumed)
        let completed = try await reopened.resumeSync(try string(resumed, "nextCursor"))
        #expect(try nativeTestField(completed, "cacheInfo", "acquisitionComplete") == .bool(true))
        #expect(try nativeTestField(completed, "cacheInfo", "processedCount") == .number(.int(3)))

        let read = try await reopened.readChanges(collection: .logs, query: query, checkpoint: nil,
            limit: 1, maxBytes: 256 * 1024, order: .occurredAtDescending)
        let firstChange = try #require(try changes(read).first)
        #expect(try nativeTestField(firstChange, "nativeLogId") == .string(second.deletingPathExtension().lastPathComponent))
        let readCursor = try string(read, "nextCursor")
        _ = try writeLog(logs, name: nativeName(day: 3), text: "arrived after the reader window")
        _ = try await reopened.synchronize(snapshot(query, logs: logs), maxRecords: 100, maxBytes: 1024 * 1024)
        let reader = try NativeCrashSyncStore(root: cache)
        let next = try await reader.resumeRead(readCursor)
        #expect(try await reader.resumeRead(readCursor) == next)
        #expect(try await reader.resumeRead(readCursor, matching: .object([
            "limit": .number(.int(1)), "max_bytes": .number(.int(256 * 1024)),
            "order": .string("occurredAtDescending"),
        ])) == next)
        await #expect(throws: NativeRuntimeError.self) {
            try await reader.resumeRead(readCursor, matching: scope(issueID: "another-issue"))
        }
        await #expect(throws: NativeRuntimeError.self) {
            try await reader.resumeRead(readCursor, matching: .object(["order": .string("observedNewestFirst")]))
        }
        await #expect(throws: NativeRuntimeError.self) {
            try await reader.resumeRead(readCursor, matching: .object(["max_bytes": .number(.int(1))]))
        }
        let nextChange = try #require(try changes(next).first)
        #expect(try nativeTestField(nextChange, "nativeLogId") == .string(first.deletingPathExtension().lastPathComponent))
        let last = try await reader.resumeRead(try string(next, "nextCursor"))
        let lastChange = try #require(try changes(last).first)
        #expect(try nativeTestField(lastChange, "nativeLogId") == .string(undated.deletingPathExtension().lastPathComponent))
        #expect(try nativeTestField(last, "cacheInfo", "readComplete") == .bool(true))
        _ = try string(last, "checkpoint")
        await #expect(throws: NativeRuntimeError.self) { try await reader.resumeRead(originalCursor) }
        await #expect(throws: NativeRuntimeError.self) { try await reader.resumeSync(readCursor) }
    }

    @Test func checkpointsReportOnlyAddedOrChangedLogsAndReuseImmutableBlobs() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(component: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let raw = try writeLog(logs, name: nativeName(day: 1), text: "raw stack")
        let query = scope()
        let store = try NativeCrashSyncStore(root: root.appending(component: "Cache"))
        _ = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 100, maxBytes: 1024 * 1024)
        let baseline = try await read(store, query: query)
        let initial = try #require(try changes(baseline).first)
        let initialID = try nativeTestField(initial, "logId")
        let originalBlob = URL(fileURLWithPath: try string(initial, "path"))
        let originalAttributes = try originalBlob.resourceValues(forKeys: [.contentModificationDateKey])
        let checkpoint = try string(baseline, "checkpoint")

        let unchanged = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 100, maxBytes: 1024 * 1024)
        #expect(try nativeTestField(unchanged, "cacheInfo", "newCount") == .number(.int(0)))
        #expect(try nativeTestField(unchanged, "cacheInfo", "updatedCount") == .number(.int(0)))
        let noChanges = try await read(store, query: query, checkpoint: checkpoint)
        #expect(try changes(noChanges).isEmpty)
        var freshBlob = originalBlob
        freshBlob.removeAllCachedResourceValues()
        #expect(try freshBlob.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            == originalAttributes.contentModificationDate)

        _ = try writeLog(logs, name: nativeName(day: 2), text: "raw stack")
        _ = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 100, maxBytes: 1024 * 1024)
        let added = try await read(store, query: query, checkpoint: checkpoint)
        let addition = try #require(try changes(added).only)
        #expect(try nativeTestField(addition, "change") == .string("new"))
        #expect(try string(addition, "path") == originalBlob.path)

        let symbolicated = logs.appending(path: "LocallySymbolicated/" + raw.lastPathComponent)
        try FileManager.default.createDirectory(at: symbolicated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("resolved stack".utf8).write(to: symbolicated)
        _ = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 100, maxBytes: 1024 * 1024)
        let updated = try await read(store, query: query, checkpoint: try string(added, "checkpoint"))
        let change = try #require(try changes(updated).only)
        #expect(try nativeTestField(change, "change") == .string("updated"))
        #expect(try nativeTestField(change, "logId") == initialID)
        let originalContent = try nativeTestField(initial, "contentId")
        #expect(try nativeTestField(change, "contentId") != originalContent)
        #expect(try nativeTestField(change, "variant") == .string("locallySymbolicated"))
        let changedBlob = URL(fileURLWithPath: try string(change, "path"))
        #expect(try Data(contentsOf: changedBlob) == Data("resolved stack".utf8))
        #expect(try Data(contentsOf: originalBlob) == Data("raw stack".utf8))

        try FileManager.default.removeItem(at: symbolicated)
        _ = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 100, maxBytes: 1024 * 1024)
        let returnedToOriginal = try await read(store, query: query, checkpoint: try string(added, "checkpoint"))
        #expect(try changes(returnedToOriginal).isEmpty)
        #expect(try await store.resumeRead(try string(updated, "cursor")) == updated)

        let independentReader = try await read(store, query: query)
        #expect(try changes(independentReader).count == 2)
        let otherQuery = scope(issueID: "another-issue")
        let otherChanges = try await read(store, query: otherQuery)
        #expect(try changes(otherChanges).isEmpty)
        await #expect(throws: NativeRuntimeError.self) {
            try await read(store, query: otherQuery, checkpoint: checkpoint)
        }
    }

    @Test func oversizedImportsAndLargeChangeMetadataRespectTheirSeparateBudgets() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(component: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x61, count: 2 * 1024 * 1024 + 17)
        try bytes.write(to: logs.appending(component: nativeName(day: 1)))
        let store = try NativeCrashSyncStore(root: root.appending(component: "Cache"))
        let imported = try await store.synchronize(snapshot(scope(), logs: logs), maxRecords: 10, maxBytes: 64)
        #expect(try nativeTestField(imported, "cacheInfo", "processedCount") == .number(.int(1)))
        #expect(try nativeTestField(imported, "cacheInfo", "acquisitionComplete") == .bool(true))
        let largeRead = try await read(store, query: scope())
        let largeLog = try #require(try changes(largeRead).first)
        let largeBlob = URL(fileURLWithPath: try string(largeLog, "path"))
        #expect(try Data(contentsOf: largeBlob) == bytes)

        let issues = scope(collection: .issues)
        let issue: JSONValue = .object(["issueId": .string("large-issue"),
            "name": .string(String(repeating: "Large.symbol() ", count: 1024)), "uniqueDeviceCount": .number(.int(1))])
        let medium: [JSONValue] = ["medium-a", "medium-b"].map { identifier in
            .object(["issueId": .string(identifier), "name": .string(String(repeating: "m", count: 1400)),
                "uniqueDeviceCount": .number(.int(1))])
        }
        _ = try await store.synchronize(.init(collection: .issues, query: issues, metadata: .object([:]), issues: [issue] + medium),
            maxRecords: 10, maxBytes: 1024 * 1024)
        await #expect(throws: NativeRuntimeError.self) {
            try await store.readChanges(collection: .issues, query: issues, checkpoint: nil,
                limit: 1, maxBytes: 1, order: .observedNewestFirst)
        }
        let oneRecord = try await store.readChanges(collection: .issues, query: issues, checkpoint: nil,
            limit: 1, maxBytes: 1024 * 1024, order: .observedNewestFirst)
        let budget = try NativeCrashStore.encode(oneRecord).count + 32
        var bounded = try await store.readChanges(collection: .issues, query: issues, checkpoint: nil,
            limit: 100, maxBytes: budget, order: .observedNewestFirst)
        #expect(try changes(bounded).count < 3)
        var records: [JSONValue] = []
        for _ in 0..<3 {
            #expect(try NativeCrashStore.encode(bounded).count <= budget)
            records += try changes(bounded)
            guard let cursor = try continuation(bounded) else { break }
            bounded = try await store.resumeRead(cursor)
        }
        #expect(records.count == 3)
        let compactRecords = try records.filter { try nativeTestField($0, "issueId") == .string("large-issue") }
        let compact = try #require(compactRecords.only)
        #expect(try nativeTestField(compact, "metadataOmitted") == .bool(true))
        let reference = URL(fileURLWithPath: try string(compact, "payloadPath"))
        #expect(FileManager.default.fileExists(atPath: reference.path))
        #expect(try nativeTestField(bounded, "cacheInfo", "readComplete") == .bool(true))
        _ = try string(bounded, "checkpoint")

        let retryLogs = root.appending(component: "BudgetResumeLogs")
        try FileManager.default.createDirectory(at: retryLogs, withIntermediateDirectories: true)
        let longName = "a-" + String(repeating: "l", count: 180) + ".crash"
        let long = try writeLog(retryLogs, name: longName, text: "sample")
        _ = try writeLog(retryLogs, name: "z.crash", text: "sample")
        let retryQuery = scope(issueID: "budget-retry")
        _ = try await store.synchronize(snapshot(retryQuery, logs: retryLogs), maxRecords: 10, maxBytes: 1024 * 1024)
        let probe = try await store.readChanges(collection: .logs, query: retryQuery, checkpoint: nil,
            limit: 1, maxBytes: 256 * 1024, order: .observedNewestFirst)
        let smallBudget = try NativeCrashStore.encode(probe).count + 32
        let shortPage = try await store.readChanges(collection: .logs, query: retryQuery, checkpoint: nil,
            limit: 1, maxBytes: smallBudget, order: .observedNewestFirst)
        let shortRecord = try #require(try changes(shortPage).only)
        #expect(try nativeTestField(shortRecord, "nativeLogId") == .string("z"))
        let retryCursor = try string(shortPage, "nextCursor")
        await #expect(throws: NativeRuntimeError.self) { try await store.resumeRead(retryCursor) }

        try FileManager.default.removeItem(at: retryLogs)
        let largerBudget = smallBudget + 1024
        let recovered = try await store.resumeRead(retryCursor,
            matching: .object(["max_bytes": .number(.int(Int64(largerBudget)))]))
        #expect(try NativeCrashStore.encode(recovered).count <= largerBudget)
        let remaining = try #require(try changes(recovered).only)
        #expect(try nativeTestField(remaining, "nativeLogId") == .string(long.deletingPathExtension().lastPathComponent))
        #expect(try nativeTestField(recovered, "cacheInfo", "readComplete") == .bool(true))
        #expect(try await store.resumeRead(retryCursor) == recovered)
        #expect(try await store.resumeRead(try string(shortPage, "cursor")) == shortPage)
        await #expect(throws: NativeRuntimeError.self) {
            try await store.resumeRead(retryCursor,
                matching: .object(["max_bytes": .number(.int(Int64(largerBudget + 1024)))]))
        }
    }

    @Test func manySmallLogsTraverseAcquisitionAndByteBoundedReaderPagesWithoutLoss() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(component: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let count = 1000
        let expected = Set((0..<count).map { "bulk-\($0)" })
        for index in 0..<count {
            _ = try writeLog(logs, name: "bulk-\(index).crash", text: "sample \(index)\n")
        }
        let query = scope()
        let store = try NativeCrashSyncStore(root: root.appending(component: "Cache"))
        var imported = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 127, maxBytes: 64 * 1024 * 1024)
        var acquisitionPages = 1
        while let cursor = try continuation(imported) {
            imported = try await store.resumeSync(cursor)
            acquisitionPages += 1
            if acquisitionPages > count { Issue.record("Acquisition did not advance through the saved logs"); break }
        }
        #expect(acquisitionPages >= 8)
        #expect(try nativeTestField(imported, "cacheInfo", "processedCount") == .number(.int(Int64(count))))

        let budget = 16 * 1024
        var page = try await store.readChanges(collection: .logs, query: query, checkpoint: nil,
            limit: 127, maxBytes: budget, order: .observedNewestFirst)
        #expect(try changes(page).count < 127)
        var received: [String] = []
        for _ in 0..<count {
            #expect(try NativeCrashStore.encode(page).count <= budget)
            let records = try changes(page)
            #expect(!records.isEmpty)
            for record in records { received.append(try string(record, "nativeLogId")) }
            guard let cursor = try continuation(page) else { break }
            page = try await store.resumeRead(cursor)
        }
        #expect(received.count == count)
        #expect(Set(received) == expected)
        #expect(try nativeTestField(page, "cacheInfo", "readComplete") == .bool(true))

        var unchanged = try await store.synchronize(snapshot(query, logs: logs), maxRecords: 127, maxBytes: 64 * 1024 * 1024)
        var retries = 0
        while let cursor = try continuation(unchanged) {
            unchanged = try await store.resumeSync(cursor)
            retries += 1
            if retries > count { Issue.record("Unchanged acquisition did not advance"); break }
        }
        #expect(try nativeTestField(unchanged, "cacheInfo", "newCount") == .number(.int(0)))
        #expect(try nativeTestField(unchanged, "cacheInfo", "updatedCount") == .number(.int(0)))
        #expect(try nativeTestField(unchanged, "cacheInfo", "storedBytes") == .number(.int(0)))
    }

    @Test func incompleteSourcesRetainUsableImportedFilesAndTheirDiagnostics() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(component: "Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        _ = try writeLog(logs, name: nativeName(day: 1), text: "available sample")
        let failure = NativeCrashData.diagnostic(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            operation: "organizerIssueRefresh")
        var partial = snapshot(scope(), logs: logs)
        partial.isComplete = false
        partial.errors = [failure]
        let store = try NativeCrashSyncStore(root: root.appending(component: "Cache"))
        let imported = try await store.synchronize(partial, maxRecords: 100, maxBytes: 1024 * 1024)
        #expect(try nativeTestField(imported, "status") == .string("partial"))
        #expect(try nativeTestField(imported, "cacheInfo", "sourceComplete") == .bool(false))
        #expect(try nativeTestField(imported, "errors") == .array([failure]))
        let observed = try await read(store, query: scope())
        let log = try #require(try changes(observed).only)
        let savedBlob = URL(fileURLWithPath: try string(log, "path"))
        #expect(try Data(contentsOf: savedBlob) == Data("available sample".utf8))
        #expect(try nativeTestField(observed, "cacheInfo", "latestSync", "sourceComplete") == .bool(false))
        #expect(try nativeTestField(observed, "cacheInfo", "readComplete") == .bool(true))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func scope(collection: NativeCrashCollection = .logs, issueID: String = "stable-issue") -> JSONValue {
        var value: [String: JSONValue] = ["collection": .string(collection.rawValue), "bundleId": .string("example.App"),
            "platform": .string("com.apple.platform.iphoneos"), "uploadPlatform": .string("com.apple.platform.iphoneos"),
            "appVersion": .null, "isBeta": .null, "timePeriod": .string("last14Days")]
        if collection == .logs { value["issueId"] = .string(issueID) }
        return .object(value)
    }

    private func snapshot(_ query: JSONValue, logs: URL) -> NativeCrashSyncSnapshot {
        NativeCrashSyncSnapshot(collection: .logs, query: query,
            metadata: .object(["provenance": .object(["source": .string("cache"), "fetchedAt": .null])]), logDirectory: logs)
    }

    private func nativeName(day: Int) -> String {
        "2024-01-0\(day)_10-00-00_+0000-" + String(repeating: "a", count: 40) + ".crash"
    }

    private func writeLog(_ directory: URL, name: String, text: String) throws -> URL {
        let url = directory.appending(component: name)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func changes(_ value: JSONValue) throws -> [JSONValue] {
        guard case .array(let records) = try nativeTestField(value, "changes") else { throw FixtureFailure.invalidValue }
        return records
    }

    private func string(_ value: JSONValue, _ name: String) throws -> String {
        guard case .string(let text) = try nativeTestField(value, name) else { throw FixtureFailure.invalidValue }
        return text
    }

    private func continuation(_ value: JSONValue) throws -> String? {
        switch try nativeTestField(value, "nextCursor") {
        case .string(let cursor): return cursor
        case .null: return nil
        default: throw FixtureFailure.invalidValue
        }
    }

    private func read(_ store: NativeCrashSyncStore, query: JSONValue, checkpoint: String? = nil) async throws -> JSONValue {
        try await store.readChanges(collection: .logs, query: query, checkpoint: checkpoint,
            limit: 100, maxBytes: 256 * 1024, order: .observedNewestFirst)
    }

    private enum FixtureFailure: Error { case invalidValue }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
