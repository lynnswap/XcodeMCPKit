import CryptoKit
import Darwin
import Foundation
import SQLite3
import XcodeMCPWire

struct NativeCrashSyncSnapshot: Sendable {
    let collection: NativeCrashCollection
    let query: JSONValue
    let metadata: JSONValue
    var issues: [JSONValue] = []
    var logDirectory: URL?
    var isComplete = true
    var errors: [JSONValue] = []
    var sourceAvailable = true
    var sourceObservedAt: Date?
}

/// Owns acquired versions and immutable reader windows. Acquisition never moves
/// a consumer checkpoint; only a completed reader window issues a new one.
actor NativeCrashSyncStore {
    let root: URL
    private let database: CrashDatabase
    private let cacheID: String

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try CrashDatabase(url: root.appending(component: "index.sqlite"))
        try database.execute("""
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS scopes (id TEXT PRIMARY KEY, collection TEXT NOT NULL, query TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS versions (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, item TEXT NOT NULL,
                content TEXT NOT NULL, payload TEXT NOT NULL, occurred REAL, observed TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS versions_scope_item ON versions(scope,item,sequence);
            CREATE INDEX IF NOT EXISTS versions_scope_sequence ON versions(scope,sequence);
            CREATE TABLE IF NOT EXISTS issue_observations (
                scope TEXT NOT NULL, item TEXT NOT NULL, source_observed REAL, run_order INTEGER NOT NULL,
                PRIMARY KEY(scope,item));
            CREATE TABLE IF NOT EXISTS sources (path TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
                content TEXT NOT NULL, bytes INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_runs (
                id TEXT PRIMARY KEY, scope TEXT NOT NULL, metadata TEXT NOT NULL, directory TEXT,
                complete INTEGER NOT NULL, source_available INTEGER NOT NULL DEFAULT 1, source_observed REAL,
                captured INTEGER NOT NULL DEFAULT 0, processed INTEGER NOT NULL DEFAULT 0,
                reused INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL DEFAULT 0,
                stored_bytes INTEGER NOT NULL DEFAULT 0, created TEXT NOT NULL, errors TEXT NOT NULL,
                capture_complete INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS work (
                run TEXT NOT NULL, item TEXT NOT NULL, payload TEXT NOT NULL, occurred REAL,
                state INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0, last_page TEXT,
                PRIMARY KEY(run,item));
            CREATE TABLE IF NOT EXISTS sync_pages (id TEXT PRIMARY KEY, run TEXT NOT NULL,
                max_records INTEGER NOT NULL, max_bytes INTEGER NOT NULL, response TEXT);
            CREATE TABLE IF NOT EXISTS read_pages (id TEXT PRIMARY KEY, scope TEXT NOT NULL,
                baseline INTEGER NOT NULL, upper_bound INTEGER NOT NULL, offset INTEGER NOT NULL,
                limit_count INTEGER NOT NULL, max_bytes INTEGER NOT NULL, ordering TEXT NOT NULL,
                total_count INTEGER NOT NULL DEFAULT -1, response TEXT);
            CREATE TABLE IF NOT EXISTS checkpoints (id TEXT PRIMARY KEY, scope TEXT NOT NULL,
                upper_bound INTEGER NOT NULL, created TEXT NOT NULL);
            """)
        try database.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('cache_id',?)", [.text(UUID().uuidString)])
        cacheID = try database.rows("SELECT value FROM settings WHERE key='cache_id'").first?.text("value") ?? ""
    }

    func synchronize(_ snapshot: NativeCrashSyncSnapshot, maxRecords: Int, maxBytes: Int) async throws -> JSONValue {
        try await locked {
            let scope = try register(snapshot.query, collection: snapshot.collection)
            let run = UUID().uuidString
            let page = UUID().uuidString
            let metadata = try saveJSON(snapshot.metadata, directory: "Metadata")
            try database.transaction {
                try database.execute("""
                    INSERT INTO sync_runs(id,scope,metadata,directory,complete,created,errors,source_available,source_observed)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, [.text(run), .text(scope), .text(metadata.path), snapshot.logDirectory.map { .text($0.path) } ?? .null,
                           .integer(snapshot.isComplete && snapshot.sourceAvailable ? 1 : 0), .text(Self.now), .text(try Self.json(.array(snapshot.errors))),
                           .integer(snapshot.sourceAvailable ? 1 : 0), snapshot.sourceObservedAt.map { .real($0.timeIntervalSince1970) } ?? .null])
                try database.execute("INSERT INTO sync_pages(id,run,max_records,max_bytes) VALUES(?,?,?,?)",
                    [.text(page), .text(run), .integer(Int64(maxRecords)), .integer(Int64(maxBytes))])
                if snapshot.collection == .issues {
                    for issue in snapshot.issues {
                        guard case .object(let fields) = issue, case .string(let identifier) = fields["issueId"] else {
                            throw NativeRuntimeError.unsupportedContract("A crash issue has no stable issueId")
                        }
                        try database.execute("INSERT OR REPLACE INTO work(run,item,payload) VALUES(?,?,?)",
                            [.text(run), .text(identifier), .text(try Self.json(issue))])
                    }
                    try database.execute("UPDATE sync_runs SET captured=?,capture_complete=1 WHERE id=?",
                        [.integer(Int64(snapshot.issues.count)), .text(run)])
                }
            }
            if snapshot.collection == .logs {
                try await captureLogs(run: run)
            }
            return try await performSync(page: page)
        }
    }

    func resumeSync(_ cursor: String, matching query: JSONValue? = nil) async throws -> JSONValue {
        try await locked {
            let id = try tokenID(cursor, kind: "sync")
            let page = try requireRow("SELECT * FROM sync_pages WHERE id=?", [.text(id)])
            let run = try requireRow("SELECT * FROM sync_runs WHERE id=?", [.text(try page.required("run"))])
            try validate(query, scope: try run.required("scope"), options: [
                "max_records": .number(.int(page.integer("max_records"))), "max_bytes": .number(.int(page.integer("max_bytes"))),
            ])
            if let response = page.text("response") { return try Self.readJSON(URL(fileURLWithPath: response)) }
            if run.integer("capture_complete") == 0 { try await captureLogs(run: try run.required("id")) }
            return try await performSync(page: id)
        }
    }

    func readChanges(collection: NativeCrashCollection?, query: JSONValue?, checkpoint: String?,
                     limit: Int, maxBytes: Int, order: NativeCrashReadOrder) async throws -> JSONValue {
        try await locked {
            let scope: String
            let baseline: Int64
            if let checkpoint {
                let id = try tokenID(checkpoint, kind: "checkpoint")
                let saved = try requireRow("SELECT * FROM checkpoints WHERE id=?", [.text(id)])
                scope = try saved.required("scope")
                baseline = saved.integer("upper_bound")
                try validate(query, scope: scope)
                if let collection {
                    let selected = try requireRow("SELECT collection FROM scopes WHERE id=?", [.text(scope)])
                    guard selected.text("collection") == collection.rawValue else {
                        throw NativeRuntimeError.invalidRequest("The checkpoint belongs to another crash collection")
                    }
                }
            } else {
                guard let collection, let query else {
                    throw NativeRuntimeError.invalidRequest("Specify the crash query, cursor, or checkpoint")
                }
                scope = try register(query, collection: collection)
                baseline = 0
            }
            let selected = try requireRow("SELECT collection FROM scopes WHERE id=?", [.text(scope)])
            if selected.text("collection") == "issues", order == .occurredAtDescending {
                throw NativeRuntimeError.invalidRequest("occurredAtDescending is available only for logs")
            }
            let upper = try database.rows("SELECT COALESCE(MAX(sequence),0) AS n FROM versions WHERE scope=?", [.text(scope)]).first?.integer("n") ?? 0
            let id = UUID().uuidString
            try database.execute("""
                INSERT INTO read_pages(id,scope,baseline,upper_bound,offset,limit_count,max_bytes,ordering)
                VALUES(?,?,?,?,0,?,?,?)
                """, [.text(id), .text(scope), .integer(baseline), .integer(upper), .integer(Int64(limit)),
                       .integer(Int64(maxBytes)), .text(order.rawValue)])
            return try performRead(page: id)
        }
    }

    func resumeRead(_ cursor: String, matching query: JSONValue? = nil) async throws -> JSONValue {
        try await locked {
            let id = try tokenID(cursor, kind: "read")
            let page = try requireRow("SELECT * FROM read_pages WHERE id=?", [.text(id)])
            let budget: Int64
            if page.text("response") == nil, case .object(let fields)? = query,
               case .number(.int(let requested))? = fields["max_bytes"], requested > page.integer("max_bytes") {
                budget = requested
            } else { budget = page.integer("max_bytes") }
            try validate(query, scope: try page.required("scope"), options: [
                "limit": .number(.int(page.integer("limit_count"))), "max_bytes": .number(.int(budget)),
                "order": .string(try page.required("ordering")),
            ])
            if budget != page.integer("max_bytes") {
                try database.execute("UPDATE read_pages SET max_bytes=? WHERE id=?", [.integer(budget), .text(id)])
            }
            return try performRead(page: id)
        }
    }

    private func locked<Value>(_ operation: () async throws -> Value) async throws -> Value {
        let path = root.appending(component: "writer.lock").path
        let descriptor = unsafe open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            let value = try await operation()
            try handle.close()
            return value
        } catch {
            do { try handle.close() }
            catch let cleanup {
                throw NSError(domain: "XcodeMCPKit.CrashIndex", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Crash cache operation and lock cleanup failed",
                    NSMultipleUnderlyingErrorsKey: [error as NSError, cleanup as NSError],
                ])
            }
            throw error
        }
    }

    private func register(_ query: JSONValue, collection: NativeCrashCollection) throws -> String {
        let json = try Self.json(query)
        let id = Self.digest(Data(json.utf8))
        try database.execute("INSERT OR IGNORE INTO scopes(id,collection,query) VALUES(?,?,?)",
            [.text(id), .text(collection.rawValue), .text(json)])
        return id
    }

    private func validate(_ constraint: JSONValue?, scope: String, options: [String: JSONValue] = [:]) throws {
        guard let constraint else { return }
        guard case .object(let expected) = constraint,
              case .object(let stored) = try Self.parse(try requireRow("SELECT query FROM scopes WHERE id=?", [.text(scope)]).required("query")) else {
            throw NativeRuntimeError.invalidRequest("The crash cursor has an invalid query")
        }
        for (key, value) in expected {
            guard (options[key] ?? stored[key]) == value else {
                throw NativeRuntimeError.invalidRequest("The saved crash cursor/checkpoint does not match \(key)")
            }
        }
    }

    private func token(_ id: String, kind: String) -> String { "crash1.\(cacheID).\(kind).\(id)" }
    private func tokenID(_ value: String, kind: String) throws -> String {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "crash1", parts[1] == cacheID, parts[2] == kind,
              UUID(uuidString: String(parts[3])) != nil else {
            throw NativeRuntimeError.invalidRequest("The \(kind) token belongs to another cache or operation, or is invalid")
        }
        return String(parts[3])
    }

    private func requireRow(_ sql: String, _ args: [CrashSQLValue]) throws -> CrashSQLRow {
        guard let row = try database.rows(sql, args).first else {
            throw NativeRuntimeError.invalidRequest("The saved crash cursor/checkpoint is unavailable in this cache")
        }
        return row
    }

    private func saveJSON(_ value: JSONValue, directory: String) throws -> URL {
        let data = try NativeCrashStore.encode(value)
        let folder = root.appending(component: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(component: Self.digest(data) + ".json")
        if !FileManager.default.fileExists(atPath: path.path) { try data.write(to: path, options: .atomic) }
        return path
    }

    private func publish(_ value: [String: JSONValue], id: String, table: String) throws -> JSONValue {
        let folder = root.appending(component: "Responses")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(component: id + ".json")
        var result = value
        result["responsePath"] = .string(path.path)
        try NativeCrashStore.encode(.object(result)).write(to: path, options: .atomic)
        try database.execute("UPDATE \(table) SET response=? WHERE id=?", [.text(path.path), .text(id)])
        return .object(result)
    }

    private func captureLogs(run: String) async throws {
        let saved = try requireRow("SELECT * FROM sync_runs WHERE id=?", [.text(run)])
        guard let directory = saved.text("directory") else {
            try database.execute("UPDATE sync_runs SET capture_complete=1 WHERE id=?", [.text(run)])
            return
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]) }
        catch {
            let native = error as NSError
            if native.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code) {
                try database.execute("UPDATE sync_runs SET capture_complete=1 WHERE id=?", [.text(run)])
                return
            }
            throw error
        }
        var enumerationFailure: (any Error)?
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in
                enumerationFailure = error
                return false
            }) else { throw NativeRuntimeError.unavailable("Could not enumerate Organizer's saved logs: \(directory)") }
        var batch: [URL] = []
        while let file = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            guard file.pathExtension == "crash" else { continue }
            batch.append(file)
            if batch.count == 128 {
                try capture(batch, run: run, scope: saved.required("scope"))
                batch.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }
        try capture(batch, run: run, scope: saved.required("scope"))
        if let enumerationFailure { throw enumerationFailure }
        try database.execute("UPDATE sync_runs SET capture_complete=1 WHERE id=?", [.text(run)])
    }

    private func capture(_ files: [URL], run: String, scope: String) throws {
        try database.transaction {
            for file in files {
                let item = file.deletingPathExtension().lastPathComponent
                if !(try database.rows("SELECT item FROM work WHERE run=? AND item=?", [.text(run), .text(item)])).isEmpty { continue }
                let payload: JSONValue = .object(["rawPath": .string(file.path)])
                let source = try? NativeCrashLogSource.inspect(rawURL: file, includeHeaderDate: false)
                let occurred = source?.occurredAt.map { CrashSQLValue.real($0.timeIntervalSince1970) } ?? .null
                var reused = false
                if let source, let previous = try database.rows("SELECT * FROM sources WHERE path=?", [.text(file.path)]).first,
                   let content = previous.text("content"), let fingerprint = previous.text("fingerprint"),
                   let decoded = try? JSONDecoder().decode(NativeCrashLogSource.Fingerprint.self, from: Data(fingerprint.utf8)),
                   NativeCrashLogSource.matchesFingerprint(decoded, source.fingerprint),
                   FileManager.default.fileExists(atPath: blobURL(content).path),
                   try database.rows("SELECT content FROM versions WHERE scope=? AND item=? ORDER BY sequence DESC LIMIT 1",
                    [.text(scope), .text(item)]).first?.text("content") == content {
                    reused = true
                }
                try database.execute("INSERT INTO work(run,item,payload,occurred,state) VALUES(?,?,?,?,?)",
                    [.text(run), .text(item), .text(try Self.json(payload)), occurred, .integer(reused ? 1 : 0)])
                try database.execute("UPDATE sync_runs SET captured=captured+1,processed=processed+?,reused=reused+? WHERE id=?",
                    [.integer(reused ? 1 : 0), .integer(reused ? 1 : 0), .text(run)])
            }
        }
    }

    private func performSync(page id: String) async throws -> JSONValue {
        let page = try requireRow("SELECT * FROM sync_pages WHERE id=?", [.text(id)])
        if let path = page.text("response") { return try Self.readJSON(URL(fileURLWithPath: path)) }
        let runID = try page.required("run")
        let run = try requireRow("SELECT rowid AS ordinal,* FROM sync_runs WHERE id=?", [.text(runID)])
        let scope = try run.required("scope")
        let scopeRow = try requireRow("SELECT * FROM scopes WHERE id=?", [.text(scope)])
        let collection = try scopeRow.required("collection")
        var failures: [JSONValue] = []
        if case .array(let sourceErrors) = try Self.parse(try run.required("errors")) { failures += sourceErrors }
        var processed = 0
        var bytes: Int64 = 0
        var oversized = false
        while Int64(processed) < page.integer("max_records") {
            guard let candidate = try database.rows("""
                SELECT * FROM work WHERE run=? AND state<>1 AND last_page IS NOT ?
                ORDER BY attempts,occurred DESC,item LIMIT 1
                """, [.text(runID), .text(id)]).first else { break }
            try Task.checkCancellation()
            let item = try candidate.required("item")
            do {
                let payload = try Self.parse(try candidate.required("payload"))
                let content: String
                let record: JSONValue
                let occurred: Double?
                let stored: Int64
                if collection == NativeCrashCollection.logs.rawValue {
                    guard case .object(let fields) = payload, case .string(let path) = fields["rawPath"] else {
                        throw NativeRuntimeError.unsupportedContract("A pending crash log has no source path")
                    }
                    let source = try NativeCrashLogSource.inspect(rawURL: URL(fileURLWithPath: path))
                    if processed > 0, source.byteCount > page.integer("max_bytes") - bytes { break }
                    oversized = oversized || source.byteCount > page.integer("max_bytes")
                    let blob = try await importLog(source, rawPath: path)
                    bytes += blob.readBytes
                    var value: [String: JSONValue] = [
                        "nativeLogId": .string(source.nativeID), "path": .string(blobURL(blob.content).path),
                        "bytes": .number(.int(source.byteCount)), "variant": .string(source.variant),
                        "occurredAt": source.occurredAt.map { .string($0.ISO8601Format()) } ?? .null,
                    ]
                    // The provider ID identifies a logical sample; its digest identifies a version.
                    var identityScope = try NativeCrashStore.object(Data(try scopeRow.required("query").utf8))
                    identityScope.removeValue(forKey: "timePeriod")
                    let identity: JSONValue = .object(["scope": .object(identityScope), "nativeLogId": .string(source.nativeID)])
                    value["logId"] = .string(Self.digest(try NativeCrashStore.encode(identity)))
                    content = blob.content
                    record = .object(value)
                    occurred = source.occurredAt?.timeIntervalSince1970
                    stored = blob.storedBytes
                } else {
                    if try isSupersededIssue(scope: scope, item: item, run: run) {
                        try database.transaction {
                            try database.execute("UPDATE work SET state=1,attempts=attempts+1,last_page=? WHERE run=? AND item=?",
                                [.text(id), .text(runID), .text(item)])
                            try database.execute("UPDATE sync_runs SET processed=processed+1,reused=reused+1 WHERE id=?", [.text(runID)])
                        }
                        processed += 1
                        continue
                    }
                    let data = try NativeCrashStore.encode(payload)
                    if processed > 0, Int64(data.count) > page.integer("max_bytes") - bytes { break }
                    oversized = oversized || Int64(data.count) > page.integer("max_bytes")
                    bytes += Int64(data.count)
                    content = Self.digest(data)
                    let path = root.appending(component: "Records").appending(component: content + ".json")
                    let existed = FileManager.default.fileExists(atPath: path.path)
                    _ = try saveJSON(payload, directory: "Records")
                    guard case .object(var fields) = payload else { throw NativeRuntimeError.unsupportedContract("A crash issue is not an object") }
                    fields.removeValue(forKey: "native")
                    fields["payloadPath"] = .string(path.path)
                    record = .object(fields)
                    occurred = nil
                    stored = existed ? 0 : Int64(data.count)
                }
                try Task.checkCancellation()
                try database.transaction {
                    guard case .object(var fields) = record else { throw NativeRuntimeError.unsupportedContract("A crash record is not an object") }
                    fields["syncId"] = .string(runID)
                    fields["metadataPath"] = .string(try run.required("metadata"))
                    if collection == NativeCrashCollection.issues.rawValue {
                        // Unchanged observations still supersede older queued issue payloads.
                        try database.execute("INSERT OR REPLACE INTO issue_observations(scope,item,source_observed,run_order) VALUES(?,?,?,?)",
                            [.text(scope), .text(item), run.real("source_observed").map(CrashSQLValue.real) ?? .null,
                             .integer(run.integer("ordinal"))])
                    }
                    let version = try storeVersion(scope: scope, item: item, content: content, payload: .object(fields), occurred: occurred)
                    try database.execute("UPDATE work SET state=1,attempts=attempts+1,last_page=? WHERE run=? AND item=?", [.text(id), .text(runID), .text(item)])
                    try database.execute("""
                        UPDATE sync_runs SET processed=processed+1,reused=reused+?,added=added+?,updated=updated+?,stored_bytes=stored_bytes+? WHERE id=?
                        """, [.integer(version.changed ? 0 : 1), .integer(version.added ? 1 : 0), .integer(version.changed && !version.added ? 1 : 0),
                               .integer(stored), .text(runID)])
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                failures.append(NativeCrashData.diagnostic(error, operation: "importCrashRecord"))
                try database.execute("UPDATE work SET state=2,attempts=attempts+1,last_page=? WHERE run=? AND item=?", [.text(id), .text(runID), .text(item)])
            }
            processed += 1
            if bytes >= page.integer("max_bytes") { break }
        }
        let pending = try database.rows("SELECT COUNT(*) AS n FROM work WHERE run=? AND state<>1", [.text(runID)]).first?.integer("n") ?? 0
        var next: String?
        if pending > 0 {
            let nextID = UUID().uuidString
            try database.execute("INSERT INTO sync_pages(id,run,max_records,max_bytes) VALUES(?,?,?,?)",
                [.text(nextID), .text(runID), .integer(page.integer("max_records")), .integer(page.integer("max_bytes"))])
            next = token(nextID, kind: "sync")
        }
        let result: [String: JSONValue] = [
            "status": .string(run.integer("source_available") == 0 ? "failed" : failures.isEmpty ? "complete" : "partial"),
            "collection": .string(collection),
            "query": try Self.parse(try scopeRow.required("query")), "cursor": .string(token(id, kind: "sync")),
            "nextCursor": next.map(JSONValue.string) ?? .null, "cacheInfo": try syncInfo(runID, next: next),
            "metadataPath": .string(try run.required("metadata")), "errors": .array(failures),
            "importedReadBytes": .number(.int(bytes)), "oversizedRecord": .bool(oversized),
        ]
        let published = try publish(result, id: id, table: "sync_pages")
        if pending == 0 { try database.execute("DELETE FROM work WHERE run=?", [.text(runID)]) }
        return published
    }

    private func isSupersededIssue(scope: String, item: String, run: CrashSQLRow) throws -> Bool {
        let observed = run.real("source_observed")
        let ordinal = run.integer("ordinal")
        guard let previous = try database.rows("SELECT * FROM issue_observations WHERE scope=? AND item=?",
            [.text(scope), .text(item)]).first else { return false }
        if let observed, let prior = previous.real("source_observed"), observed != prior { return observed < prior }
        return ordinal < previous.integer("run_order")
    }

    private func storeVersion(scope: String, item: String, content: String, payload: JSONValue,
                              occurred: Double?) throws -> (changed: Bool, added: Bool) {
        let old = try database.rows("SELECT content FROM versions WHERE scope=? AND item=? ORDER BY sequence DESC LIMIT 1", [.text(scope), .text(item)]).first
        guard old?.text("content") != content else { return (false, false) }
        try database.execute("INSERT INTO versions(scope,item,content,payload,occurred,observed) VALUES(?,?,?,?,?,?)",
            [.text(scope), .text(item), .text(content), .text(try Self.json(payload)), occurred.map(CrashSQLValue.real) ?? .null, .text(Self.now)])
        return (true, old == nil)
    }

    private func blobURL(_ content: String) -> URL {
        root.appending(component: "Blobs").appending(component: content + ".crash")
    }

    private func importLog(_ source: NativeCrashLogSource, rawPath: String) async throws -> (content: String, readBytes: Int64, storedBytes: Int64) {
        if let old = try database.rows("SELECT * FROM sources WHERE path=?", [.text(rawPath)]).first,
           let encoded = old.text("fingerprint"), let content = old.text("content"),
           let previous = try? JSONDecoder().decode(NativeCrashLogSource.Fingerprint.self, from: Data(encoded.utf8)),
           NativeCrashLogSource.matchesFingerprint(previous, source.fingerprint),
           FileManager.default.fileExists(atPath: blobURL(content).path) {
            return (content, 0, 0)
        }
        let folder = root.appending(component: "Blobs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(component: UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw NativeRuntimeError.unavailable("Could not create the crash blob staging file: \(temporary.path)")
        }
        var input: FileHandle?
        var output: FileHandle?
        do {
            input = try FileHandle(forReadingFrom: source.url)
            output = try FileHandle(forWritingTo: temporary)
            var hash = SHA256()
            var bytes: Int64 = 0
            while let data = try input?.read(upToCount: 64 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
                try output?.write(contentsOf: data)
                bytes += Int64(data.count)
                await Task.yield()
            }
            try input?.close()
            input = nil
            try output?.synchronize()
            try output?.close()
            output = nil
            let after = try NativeCrashLogSource.fingerprint(at: source.url)
            guard after == source.fingerprint, bytes == source.byteCount else {
                throw NativeRuntimeError.unavailable("Organizer changed the saved crash sample while it was being copied: \(source.url.path)")
            }
            try Task.checkCancellation()
            let content = hash.finalize().hexString
            let destination = blobURL(content)
            let exists = FileManager.default.fileExists(atPath: destination.path)
            if exists { try FileManager.default.removeItem(at: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            let fingerprint = String(decoding: try JSONEncoder().encode(source.fingerprint), as: UTF8.self)
            try database.execute("INSERT OR REPLACE INTO sources(path,fingerprint,content,bytes) VALUES(?,?,?,?)",
                [.text(rawPath), .text(fingerprint), .text(content), .integer(bytes)])
            return (content, bytes, exists ? 0 : bytes)
        } catch {
            var cleanup: [NSError] = []
            do { try input?.close() } catch { cleanup.append(error as NSError) }
            do { try output?.close() } catch { cleanup.append(error as NSError) }
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) } catch { cleanup.append(error as NSError) }
            }
            if !cleanup.isEmpty {
                let failure = NSError(domain: "XcodeMCPKit.CrashIndex", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Crash sample import and staging cleanup failed",
                    NSMultipleUnderlyingErrorsKey: [error as NSError] + cleanup,
                ])
                if Task.isCancelled { NativeExecutionOperations.scope?.recordFailure(failure) }
                throw failure
            }
            throw error
        }
    }

    private func syncInfo(_ runID: String, next: String? = nil) throws -> JSONValue {
        let run = try requireRow("SELECT * FROM sync_runs WHERE id=?", [.text(runID)])
        let pending = try database.rows("SELECT COUNT(*) AS n FROM work WHERE run=? AND state<>1", [.text(runID)]).first?.integer("n") ?? 0
        let failed = try database.rows("SELECT COUNT(*) AS n FROM work WHERE run=? AND state=2", [.text(runID)]).first?.integer("n") ?? 0
        let complete = pending == 0 && run.integer("capture_complete") != 0
            && run.integer("complete") != 0 && run.integer("source_available") != 0
        let continuation: String?
        if let next { continuation = next }
        else if pending > 0 || run.integer("capture_complete") == 0,
                let page = try database.rows("SELECT id FROM sync_pages WHERE run=? ORDER BY rowid DESC LIMIT 1", [.text(runID)]).first?.text("id") {
            continuation = token(page, kind: "sync")
        } else { continuation = nil }
        return .object([
            "cachePath": .string(root.path), "syncId": .string(runID), "capturedCount": .number(.int(run.integer("captured"))),
            "processedCount": .number(.int(run.integer("processed"))), "pendingCount": .number(.int(pending)),
            "failedCount": .number(.int(failed)), "reusedCount": .number(.int(run.integer("reused"))),
            "newCount": .number(.int(run.integer("added"))), "updatedCount": .number(.int(run.integer("updated"))),
            "storedBytes": .number(.int(run.integer("stored_bytes"))), "sourceComplete": .bool(run.integer("complete") != 0),
            "sourceAvailable": .bool(run.integer("source_available") != 0),
            "acquisitionComplete": .bool(complete), "captureComplete": .bool(run.integer("capture_complete") != 0),
            "nextSyncCursor": continuation.map(JSONValue.string) ?? .null,
            "coverage": .string("savedOrganizerSamplesObserved"), "createdAt": .string(try run.required("created")),
        ])
    }

    private func performRead(page id: String) throws -> JSONValue {
        let page = try requireRow("SELECT * FROM read_pages WHERE id=?", [.text(id)])
        if let path = page.text("response") { return try Self.readJSON(URL(fileURLWithPath: path)) }
        let scope = try page.required("scope")
        let scopeRow = try requireRow("SELECT * FROM scopes WHERE id=?", [.text(scope)])
        let baseline = page.integer("baseline"), upper = page.integer("upper_bound")
        let clause = """
            v.scope=? AND v.sequence>? AND v.sequence=(SELECT MAX(n.sequence) FROM versions n WHERE n.scope=v.scope AND n.item=v.item AND n.sequence<=?)
            AND v.content IS NOT (SELECT b.content FROM versions b WHERE b.scope=v.scope AND b.item=v.item AND b.sequence<=? ORDER BY b.sequence DESC LIMIT 1)
            """
        let args: [CrashSQLValue] = [.text(scope), .integer(baseline), .integer(upper), .integer(baseline)]
        let total: Int64
        if page.integer("total_count") >= 0 { total = page.integer("total_count") }
        else {
            total = try database.rows("SELECT COUNT(*) AS n FROM versions v WHERE \(clause)", args).first?.integer("n") ?? 0
            try database.execute("UPDATE read_pages SET total_count=? WHERE id=?", [.integer(total), .text(id)])
        }
        let ordering = page.text("ordering") == NativeCrashReadOrder.occurredAtDescending.rawValue
            ? "v.occurred IS NULL,v.occurred DESC,v.sequence DESC,v.item" : "v.sequence DESC,v.item"
        var changes: [JSONValue] = []
        let nextID = UUID().uuidString, checkpointID = UUID().uuidString
        let latest = try database.rows("SELECT id,metadata FROM sync_runs WHERE scope=? ORDER BY rowid DESC LIMIT 1", [.text(scope)]).first
        let baseInfo: [String: JSONValue] = [
            "cachePath": .string(root.path), "baselineSequence": .number(.int(baseline)), "snapshotSequence": .number(.int(upper)),
            "totalChanges": .number(.int(total)), "readOffset": .number(.int(page.integer("offset"))),
            "order": .string(try page.required("ordering")),
            "latestSync": try latest.map { try syncInfo($0.required("id")) } ?? .null,
        ]
        var envelopeFields: [String: JSONValue] = [
            "status": .string("complete"), "collection": .string(try scopeRow.required("collection")),
            "query": try Self.parse(try scopeRow.required("query")), "cursor": .string(token(id, kind: "read")),
            "errors": .array([]),
        ]
        if let metadata = latest?.text("metadata") { envelopeFields["metadataPath"] = .string(metadata) }
        let responsePath = root.appending(component: "Responses").appending(component: id + ".json").path
        envelopeFields["responsePath"] = .string(responsePath)
        let baseResult = envelopeFields
        func response(count: Int, values: [JSONValue]) -> [String: JSONValue] {
            var info = baseInfo
            var result = baseResult
            let offset = page.integer("offset") + Int64(count)
            let complete = offset >= total
            info["returnedCount"] = .number(.int(Int64(count)))
            info["readComplete"] = .bool(complete)
            result["changes"] = .array(values)
            result["nextCursor"] = complete ? .null : .string(token(nextID, kind: "read"))
            result["checkpoint"] = complete ? .string(token(checkpointID, kind: "checkpoint")) : .null
            result["cacheInfo"] = .object(info)
            return result
        }
        var recordBytes = 0
        try database.forEachRow("SELECT v.* FROM versions v WHERE \(clause) ORDER BY \(ordering) LIMIT ? OFFSET ?",
            args + [.integer(page.integer("limit_count")), .integer(page.integer("offset"))]) { row in
            guard case .object(var fields) = try Self.parse(try row.required("payload")) else {
                throw NativeRuntimeError.unsupportedContract("A cached crash record has no object payload")
            }
            let previous = try database.rows("SELECT content FROM versions WHERE scope=? AND item=? AND sequence<=? ORDER BY sequence DESC LIMIT 1",
                [.text(scope), .text(try row.required("item")), .integer(baseline)]).first?.text("content")
            fields["itemId"] = .string(try row.required("item"))
            fields["contentId"] = .string(try row.required("content"))
            fields["revision"] = .number(.int(row.integer("sequence")))
            fields["change"] = .string(previous == nil ? "new" : "updated")
            fields["previousContentId"] = previous.map(JSONValue.string) ?? .null
            fields["observedAt"] = .string(try row.required("observed"))
            let count = changes.count + 1
            let envelope = try NativeCrashStore.encode(.object(response(count: count, values: []))).count
            var size = try NativeCrashStore.encode(.object(fields)).count
            if Int64(envelope + recordBytes + size + count - 1) > page.integer("max_bytes") {
                if !changes.isEmpty { return false }
                if fields["payloadPath"] != nil {
                    let keep = Set(["issueId", "itemId", "contentId", "revision", "change", "previousContentId", "payloadPath", "observedAt", "syncId", "metadataPath"])
                    fields = fields.filter { keep.contains($0.key) }
                    fields["metadataOmitted"] = .bool(true)
                    size = try NativeCrashStore.encode(.object(fields)).count
                }
                guard Int64(envelope + size) <= page.integer("max_bytes") else {
                    throw NativeRuntimeError.invalidRequest("max_bytes is too small for this response; at least \(envelope + size) bytes are required")
                }
            }
            changes.append(.object(fields))
            recordBytes += size
            return true
        }
        let result = response(count: changes.count, values: changes)
        let encoded = try NativeCrashStore.encode(.object(result))
        guard Int64(encoded.count) <= page.integer("max_bytes") else {
            throw NativeRuntimeError.invalidRequest("max_bytes is too small for this response; at least \(encoded.count) bytes are required")
        }
        let offset = page.integer("offset") + Int64(changes.count)
        let response = try database.transaction {
            if offset < total {
                try database.execute("INSERT INTO read_pages(id,scope,baseline,upper_bound,offset,limit_count,max_bytes,ordering,total_count) VALUES(?,?,?,?,?,?,?,?,?)",
                    [.text(nextID), .text(scope), .integer(baseline), .integer(upper), .integer(offset),
                     .integer(page.integer("limit_count")), .integer(page.integer("max_bytes")), .text(try page.required("ordering")), .integer(total)])
            } else {
                try database.execute("INSERT INTO checkpoints(id,scope,upper_bound,created) VALUES(?,?,?,?)",
                    [.text(checkpointID), .text(scope), .integer(upper), .text(Self.now)])
            }
            return try publish(result, id: id, table: "read_pages")
        }
        return response
    }

    private static var now: String { Date().ISO8601Format() }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).hexString }
    private static func json(_ value: JSONValue) throws -> String { String(decoding: try NativeCrashStore.encode(value), as: UTF8.self) }
    private static func parse(_ value: String) throws -> JSONValue {
        guard let result = JSONValue(any: try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) else {
            throw NativeRuntimeError.unsupportedContract("The crash index contains invalid JSON")
        }
        return result
    }
    private static func readJSON(_ url: URL) throws -> JSONValue { try parse(String(decoding: Data(contentsOf: url), as: UTF8.self)) }
}

private enum CrashSQLValue {
    case text(String), integer(Int64), real(Double), null
}

private struct CrashSQLRow {
    let values: [String: CrashSQLValue]
    func text(_ key: String) -> String? { if case .text(let value) = values[key] { value } else { nil } }
    func integer(_ key: String) -> Int64 { if case .integer(let value) = values[key] { value } else { 0 } }
    func real(_ key: String) -> Double? {
        switch values[key] { case .real(let value): value; case .integer(let value): Double(value); default: nil }
    }
    func required(_ key: String) throws -> String {
        guard let value = text(key) else { throw NativeRuntimeError.unsupportedContract("The crash index is missing \(key)") }
        return value
    }
}

@safe
private final class CrashDatabase {
    private let handle: OpaquePointer
    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = unsafe sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened = unsafe opened else {
            if let opened = unsafe opened { _ = unsafe sqlite3_close(opened) }
            throw NSError(domain: "XcodeMCPKit.CrashIndex", code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "Could not open the crash index", NSFilePathErrorKey: url.path])
        }
        unsafe (handle = opened)
        _ = unsafe sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
    }

    deinit { _ = unsafe sqlite3_close(handle) }

    func execute(_ sql: String, _ arguments: [CrashSQLValue] = []) throws {
        if arguments.isEmpty {
            let code = unsafe sqlite3_exec(handle, sql, nil, nil, nil)
            guard code == SQLITE_OK else { throw failure(code) }
            return
        }
        let statement = try unsafe prepare(sql, arguments)
        defer { _ = unsafe sqlite3_finalize(statement) }
        let result = unsafe sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure(result) }
    }

    func rows(_ sql: String, _ arguments: [CrashSQLValue] = []) throws -> [CrashSQLRow] {
        var result: [CrashSQLRow] = []
        try forEachRow(sql, arguments) { row in
            result.append(row)
            return true
        }
        return result
    }

    func forEachRow(_ sql: String, _ arguments: [CrashSQLValue] = [], _ body: (CrashSQLRow) throws -> Bool) throws {
        let statement = try unsafe prepare(sql, arguments)
        defer { _ = unsafe sqlite3_finalize(statement) }
        while true {
            let code = unsafe sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure(code) }
            var row: [String: CrashSQLValue] = [:]
            for column in 0..<(unsafe sqlite3_column_count(statement)) {
                let name = unsafe String(cString: sqlite3_column_name(statement, column))
                switch unsafe sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(unsafe sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(unsafe sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let pointer = unsafe sqlite3_column_text(statement, column) {
                        row[name] = .text(unsafe String(cString: pointer))
                    }
                default: row[name] = .null
                }
            }
            guard try body(CrashSQLRow(values: row)) else { return }
        }
    }

    func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            do { try execute("ROLLBACK") }
            catch let rollback {
                throw NSError(domain: "XcodeMCPKit.CrashIndex", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Crash index operation and rollback failed",
                    NSMultipleUnderlyingErrorsKey: [error as NSError, rollback as NSError],
                ])
            }
            throw error
        }
    }

    private func prepare(_ sql: String, _ arguments: [CrashSQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = unsafe sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement = unsafe statement else { throw failure(code) }
        do {
            for (offset, value) in arguments.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let string):
                    result = string.withCString { value in
                        unsafe sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                case .integer(let number): result = unsafe sqlite3_bind_int64(statement, index, number)
                case .real(let number): result = unsafe sqlite3_bind_double(statement, index, number)
                case .null: result = unsafe sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw failure(result) }
            }
            return unsafe statement
        } catch {
            _ = unsafe sqlite3_finalize(statement)
            throw error
        }
    }

    private func failure(_ code: Int32) -> NSError {
        NSError(domain: "XcodeMCPKit.CrashIndex", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: unsafe String(cString: sqlite3_errmsg(handle)),
        ])
    }
}
