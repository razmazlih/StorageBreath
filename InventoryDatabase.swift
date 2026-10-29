import Foundation
import SQLite3

struct InventorySnapshot {
    let identity: String
    let modified: Date
    let logicalSize: Int
    let allowed: Bool
    let root: URL
}
struct InventoryStats {
    let count: Int
    let bytes: Int64
    let temporaryCount: Int
    let temporaryBytes: Int64
    let categories: [(String, Int64)]
}
struct InventoryQuery {
    var search: String = ""
    var section: String = "הכול"
    var sort: String = "largest"
    var minimum: Int64 = 0
    var ageDays: Int = 0
    var offset: Int = 0
    var limit: Int = 100
    var protected: [ProtectionEntry] = []
    var actionableOnly: Bool = false
}
struct InventoryPage { let files: [DeepFile]; let total: Int }
struct InventorySelection { let files: [DeepFile]; let total: Int; let bytes: Int64 }
struct InventoryJob { let directory: URL; let root: URL; let recordFirst: Bool }
struct InventoryScanState { let roots: [URL]; let incomplete: Bool; let pendingCount: Int }

/// Persistent inventory: writer is serialized; readers use independent WAL
/// connections and retain only the requested page, never a full scan in memory.
final class InventoryDatabase: @unchecked Sendable {
    let url: URL
    private let writer: OpaquePointer
    private let lock = NSRecursiveLock()
    private struct CountKey: Hashable { let revision: Int64; let filters: [String] }
    private var countCache: [CountKey:Int] = [:]
    private var cachedEntryStatement: OpaquePointer?
    private final class CancellationCheck {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private enum Value { case text(String), integer(Int64), real(Double), null }
    enum Failure: LocalizedError {
        case sqlite(String)
        var errorDescription: String? { if case .sqlite(let text) = self { return "שגיאת אינדקס האחסון: " + text }; return nil }
    }
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open index"
            if let connection { sqlite3_close(connection) }
            throw Failure.sqlite(message)
        }
        writer = connection
        do {
            sqlite3_busy_timeout(writer, 5000)
            try Self.execute(writer, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA recursive_triggers=ON; PRAGMA cache_size=-4096; PRAGMA temp_store=FILE;")
            try Self.execute(writer, """
            CREATE TABLE IF NOT EXISTS inventory_revision(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL);
            INSERT OR IGNORE INTO inventory_revision VALUES(1,0);
            CREATE TABLE IF NOT EXISTS files (
              path TEXT PRIMARY KEY, id TEXT NOT NULL, title TEXT NOT NULL, category TEXT NOT NULL,
              bytes INTEGER NOT NULL, modified REAL NOT NULL, temporary INTEGER NOT NULL,
              reason TEXT NOT NULL, can_trash INTEGER NOT NULL, identity TEXT,
              logical_size INTEGER, snapshot_modified REAL, snapshot_allowed INTEGER, root TEXT
            );
            CREATE INDEX IF NOT EXISTS files_size ON files(bytes DESC,path);
            CREATE INDEX IF NOT EXISTS files_modified ON files(modified,path);
            CREATE INDEX IF NOT EXISTS files_title ON files(title COLLATE NOCASE,path);
            CREATE INDEX IF NOT EXISTS files_category ON files(category);
            CREATE TABLE IF NOT EXISTS issues (id INTEGER PRIMARY KEY, path TEXT NOT NULL, reason TEXT NOT NULL, UNIQUE(path,reason));
            CREATE TABLE IF NOT EXISTS totals (singleton INTEGER PRIMARY KEY CHECK(singleton=1), count INTEGER NOT NULL, bytes INTEGER NOT NULL, temporary_count INTEGER NOT NULL, temporary_bytes INTEGER NOT NULL);
            INSERT OR IGNORE INTO totals VALUES(1,0,0,0,0);
            CREATE TABLE IF NOT EXISTS categories(category TEXT PRIMARY KEY,count INTEGER NOT NULL,bytes INTEGER NOT NULL);
            CREATE TRIGGER IF NOT EXISTS files_insert AFTER INSERT ON files BEGIN
              UPDATE totals SET count=count+1,bytes=bytes+NEW.bytes,temporary_count=temporary_count+NEW.temporary,temporary_bytes=temporary_bytes+NEW.bytes*NEW.temporary WHERE singleton=1;
              INSERT INTO categories VALUES(NEW.category,1,NEW.bytes) ON CONFLICT(category) DO UPDATE SET count=count+1,bytes=bytes+NEW.bytes;
            END;
            CREATE TRIGGER IF NOT EXISTS files_delete AFTER DELETE ON files BEGIN
              UPDATE totals SET count=count-1,bytes=bytes-OLD.bytes,temporary_count=temporary_count-OLD.temporary,temporary_bytes=temporary_bytes-OLD.bytes*OLD.temporary WHERE singleton=1;
              UPDATE categories SET count=count-1,bytes=bytes-OLD.bytes WHERE category=OLD.category;
            END;
            CREATE TABLE IF NOT EXISTS scan_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),roots TEXT NOT NULL,incomplete INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS jobs(directory TEXT PRIMARY KEY,root TEXT NOT NULL,record_first INTEGER NOT NULL,state INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS jobs_pending ON jobs(state,directory);
            CREATE INDEX IF NOT EXISTS jobs_pending_fifo ON jobs(state);
            """)
            // Bootstrap old inventories once while excluding concurrent writers.
            // Thereafter directory progress reads one persisted row, never jobs.
            try Self.execute(writer,"BEGIN IMMEDIATE")
            do {
                try Self.execute(writer,"CREATE TABLE IF NOT EXISTS job_totals(singleton INTEGER PRIMARY KEY CHECK(singleton=1),discovered INTEGER NOT NULL,completed INTEGER NOT NULL)")
                let existing = try Self.prepare(writer,"SELECT 1 FROM job_totals WHERE singleton=1")
                let initialized = sqlite3_step(existing) == SQLITE_ROW
                sqlite3_finalize(existing)
                if !initialized {
                    try Self.execute(writer,"INSERT INTO job_totals SELECT 1,COUNT(*),COALESCE(SUM(CASE WHEN state=2 THEN 1 ELSE 0 END),0) FROM jobs")
                }
                try Self.execute(writer,"""
                CREATE TRIGGER IF NOT EXISTS jobs_totals_insert AFTER INSERT ON jobs BEGIN
                  UPDATE job_totals SET discovered=discovered+1,completed=completed+(NEW.state=2) WHERE singleton=1;
                END;
                CREATE TRIGGER IF NOT EXISTS jobs_totals_delete AFTER DELETE ON jobs BEGIN
                  UPDATE job_totals SET discovered=discovered-1,completed=completed-(OLD.state=2) WHERE singleton=1;
                END;
                CREATE TRIGGER IF NOT EXISTS jobs_totals_update AFTER UPDATE OF state ON jobs WHEN OLD.state<>NEW.state BEGIN
                  UPDATE job_totals SET completed=completed+(NEW.state=2)-(OLD.state=2) WHERE singleton=1;
                END;
                COMMIT;
                """)
            } catch { try? Self.execute(writer,"ROLLBACK"); throw error }
            let versionStatement = try Self.prepare(writer,"PRAGMA user_version")
            let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement,0) : 0
            sqlite3_finalize(versionStatement)
            if version < 1 {
                // The initial development schema used Unix seconds. Preserve its
                // cached dates while all new writes retain Date's native epoch.
                try Self.execute(writer,"BEGIN IMMEDIATE; UPDATE files SET modified=modified-978307200.0,snapshot_modified=snapshot_modified-978307200.0 WHERE modified IS NOT NULL; PRAGMA user_version=1; COMMIT;")
            }
            for path in [url.path,url.path+"-wal",url.path+"-shm"] {
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
            }
        } catch { sqlite3_close(writer); throw error }
    }
    deinit { if let cachedEntryStatement { sqlite3_finalize(cachedEntryStatement) }; sqlite3_close(writer) }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
        return statement
    }
    private static func bind(_ values: [Value], to statement: OpaquePointer, db: OpaquePointer) throws {
        for (offset,value) in values.enumerated() {
            let index = Int32(offset+1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement,index,text,-1,transient)
            case .integer(let number): code = sqlite3_bind_int64(statement,index,number)
            case .real(let number): code = sqlite3_bind_double(statement,index,number)
            case .null: code = sqlite3_bind_null(statement,index)
            }
            guard code == SQLITE_OK else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
        }
    }
    private static func done(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
    }
    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement,column) else { return "" }
        return String(cString:pointer)
    }
    private func transaction<T>(inventoryChanged: Bool = false, _ work: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try Self.execute(writer,"BEGIN IMMEDIATE")
        do {
            let value = try work()
            if inventoryChanged { try Self.execute(writer,"UPDATE inventory_revision SET version=version+1 WHERE singleton=1") }
            try Self.execute(writer,"COMMIT")
            if inventoryChanged { countCache.removeAll(keepingCapacity:true) }
            return value
        }
        catch { try? Self.execute(writer,"ROLLBACK"); throw error }
    }
    private func read<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path,&handle,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }; throw Failure.sqlite("cannot open inventory reader")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle,5000)
        try Self.execute(handle,"PRAGMA cache_size=-2048; PRAGMA temp_store=FILE;")
        return try work(handle)
    }
    private func resetLocked() throws {
        try Self.execute(writer,"DELETE FROM files; DELETE FROM issues; DELETE FROM jobs; DELETE FROM scan_meta; DELETE FROM categories; UPDATE totals SET count=0,bytes=0,temporary_count=0,temporary_bytes=0 WHERE singleton=1;")
    }
    func reset() throws { try transaction(inventoryChanged:true) { try resetLocked() } }
    func insert(file: DeepFile, snapshot: InventorySnapshot?) throws { try insertBatch([(file,snapshot)]) }
    func insertBatch(_ entries: [(DeepFile, InventorySnapshot?)]) throws {
        guard !entries.isEmpty else { return }
        try transaction(inventoryChanged:true) {
            let statement = try Self.prepare(writer,"INSERT OR REPLACE INTO files(path,id,title,category,bytes,modified,temporary,reason,can_trash,identity,logical_size,snapshot_modified,snapshot_allowed,root) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            for (file,snapshot) in entries {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                var values: [Value] = [.text(file.path),.text(file.id),.text(file.title),.text(file.category),.integer(max(0,file.bytes)),.real(file.modified.timeIntervalSinceReferenceDate),.integer(file.isTemporary ? 1:0),.text(file.reason),.integer(file.canTrash ? 1:0)]
                if let snapshot { values += [.text(snapshot.identity),.integer(Int64(snapshot.logicalSize)),.real(snapshot.modified.timeIntervalSinceReferenceDate),.integer(snapshot.allowed ? 1:0),.text(snapshot.root.path)] }
                else { values += Array(repeating:.null,count:5) }
                try Self.bind(values,to:statement,db:writer); try Self.done(statement,db:writer)
            }
        }
    }
    func addIssues(_ issues: [DeepIssue]) throws {
        guard !issues.isEmpty else { return }
        try transaction {
            let statement = try Self.prepare(writer,"INSERT OR IGNORE INTO issues(path,reason) VALUES(?,?)")
            defer { sqlite3_finalize(statement) }
            for issue in issues {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try Self.bind([.text(issue.path),.text(issue.reason)],to:statement,db:writer); try Self.done(statement,db:writer)
            }
        }
    }
    func stats() throws -> InventoryStats {
        try read { db in
            let statement = try Self.prepare(db,"SELECT count,bytes,temporary_count,temporary_bytes FROM totals WHERE singleton=1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.sqlite("inventory totals unavailable") }
            let count = Int(sqlite3_column_int64(statement,0)), bytes = sqlite3_column_int64(statement,1)
            let temporaryCount = Int(sqlite3_column_int64(statement,2)), temporaryBytes = sqlite3_column_int64(statement,3)
            let cats = try Self.prepare(db,"SELECT category,bytes FROM categories WHERE count>0 ORDER BY bytes DESC,category")
            defer { sqlite3_finalize(cats) }
            var categories: [(String,Int64)] = []
            while sqlite3_step(cats) == SQLITE_ROW { categories.append((Self.string(cats,0),sqlite3_column_int64(cats,1))) }
            return InventoryStats(count:count,bytes:bytes,temporaryCount:temporaryCount,temporaryBytes:temporaryBytes,categories:categories)
        }
    }
    private static func installProtections(_ rules: [ProtectionEntry], db: OpaquePointer) throws {
        try execute(db,"CREATE TEMP TABLE protected_paths(path TEXT PRIMARY KEY);")
        let statement = try prepare(db,"INSERT OR IGNORE INTO protected_paths VALUES(?)")
        defer { sqlite3_finalize(statement) }
        let now = Date()
        for rule in rules where rule.until == nil || rule.until! > now {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind([.text(rule.path)],to:statement,db:db); try done(statement,db:db)
        }
    }
    private static func conditions(_ request: InventoryQuery, allowedOnly: Bool = false) -> (String,[Value]) {
        var clauses: [String] = []
        if request.protected.contains(where: { $0.until == nil || $0.until! > Date() }) {
            clauses.append("NOT EXISTS (SELECT 1 FROM protected_paths p WHERE p.path='/' OR f.path=p.path OR substr(f.path,1,length(p.path)+1)=p.path||'/' OR substr(p.path,1,length(f.path)+1)=f.path||'/')")
        }
        var bindings: [Value] = []
        if allowedOnly || request.actionableOnly { clauses.append("f.can_trash=1") }
        if request.section == "זמניים" { clauses.append("f.temporary=1") }
        else if request.section == "גדולים" { clauses.append("f.bytes>=104857600") }
        else if request.section != "הכול" { clauses.append("f.category=?"); bindings.append(.text(request.section)) }
        if request.minimum > 0 { clauses.append("f.bytes>=?"); bindings.append(.integer(request.minimum)) }
        if request.ageDays > 0 {
            clauses.append("f.modified<=?")
            bindings.append(.real(Date().addingTimeInterval(-Double(request.ageDays)*86400).timeIntervalSinceReferenceDate))
        }
        // Keep literal, case-insensitive substring matching (including Hebrew
        // and partial names). Word-token FTS would change those semantics; this
        // scan remains cancellable and its count is reused across page changes.
        for token in request.search.split(whereSeparator: { $0.isWhitespace }) {
            clauses.append("instr(lower(f.title||' '||f.path||' '||f.reason),lower(?))>0")
            bindings.append(.text(String(token)))
        }
        return (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator:" AND "),bindings)
    }
    private static func order(_ key: String) -> String {
        switch key {
        case "smallest": return " ORDER BY f.bytes ASC,f.path"
        case "oldest": return " ORDER BY f.modified ASC,f.path"
        case "newest": return " ORDER BY f.modified DESC,f.path"
        case "name": return " ORDER BY f.title COLLATE NOCASE,f.path"
        default: return " ORDER BY f.bytes DESC,f.path"
        }
    }
    private static let fileColumns = "f.path,f.id,f.title,f.category,f.bytes,f.modified,f.temporary,f.reason,f.can_trash"
    private static func decodeFile(_ statement: OpaquePointer) -> DeepFile {
        DeepFile(id:string(statement,1),path:string(statement,0),title:string(statement,2),category:string(statement,3),bytes:sqlite3_column_int64(statement,4),modified:Date(timeIntervalSinceReferenceDate:sqlite3_column_double(statement,5)),isTemporary:sqlite3_column_int(statement,6) != 0,reason:string(statement,7),canTrash:sqlite3_column_int(statement,8) != 0)
    }
    /// SQLite's VM checks cancellation during COUNT, filtering and sorting too,
    /// so an obsolete search releases a serial UI queue before its next result.
    private static func withCancellation<T>(_ db: OpaquePointer, _ check: (() -> Bool)?, _ work: () throws -> T) throws -> T {
        guard let check else { return try work() }
        let box = CancellationCheck(check)
        let pointer = Unmanaged.passRetained(box).toOpaque()
        defer { sqlite3_progress_handler(db,0,nil,nil); Unmanaged<CancellationCheck>.fromOpaque(pointer).release() }
        sqlite3_progress_handler(db,1000,{ context in
            guard let context else { return 0 }
            return Unmanaged<CancellationCheck>.fromOpaque(context).takeUnretainedValue().check() ? 1 : 0
        },pointer)
        if check() { throw CancellationError() }
        do { let value = try work(); if check() { throw CancellationError() }; return value }
        catch { if check() { throw CancellationError() }; throw error }
    }
    func query(request: InventoryQuery, isCancelled: (() -> Bool)? = nil) throws -> InventoryPage {
        try read { db in try Self.withCancellation(db,isCancelled) {
            // Freeze active protections once for both the cache key and SQL.
            var request = request
            let now = Date()
            request.protected = request.protected.filter { $0.until == nil || $0.until! > now }.map { ProtectionEntry(path:$0.path,until:nil) }
            try Self.installProtections(request.protected,db:db)
            let (whereSQL,bindings) = Self.conditions(request)
            // Count and page share a read transaction: no mismatched page counts
            // while the scanner commits its next batch.
            try Self.execute(db,"BEGIN DEFERRED")
            defer { try? Self.execute(db,"ROLLBACK") }
            // Read a durable revision within the same WAL snapshot as the page.
            // This also invalidates cached counts after writes by another instance.
            let revisionStatement = try Self.prepare(db,"SELECT version FROM inventory_revision WHERE singleton=1")
            defer { sqlite3_finalize(revisionStatement) }
            guard sqlite3_step(revisionStatement) == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
            let key = CountKey(revision:sqlite3_column_int64(revisionStatement,0),filters:[request.search,request.section,String(request.minimum),String(request.ageDays),String(request.actionableOnly)] + request.protected.map(\.path).sorted())
            lock.lock(); let cached = request.ageDays == 0 ? countCache[key] : nil; lock.unlock()
            let total: Int
            if let cached { total = cached }
            else {
                // The unfiltered inventory already maintains an exact count.
                let countSQL = whereSQL.isEmpty ? "SELECT count FROM totals WHERE singleton=1" : "SELECT COUNT(*) FROM files f" + whereSQL
                let count = try Self.prepare(db,countSQL)
                defer { sqlite3_finalize(count) }
                try Self.bind(bindings,to:count,db:db)
                guard sqlite3_step(count) == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
                total = Int(sqlite3_column_int64(count,0))
                // A moving age cutoff must always be reevaluated.
                if request.ageDays == 0 {
                    lock.lock()
                    if countCache.count >= 32 { countCache.removeAll(keepingCapacity:true) }
                    countCache[key] = total
                    lock.unlock()
                }
            }
            let statement = try Self.prepare(db,"SELECT " + Self.fileColumns + " FROM files f" + whereSQL + Self.order(request.sort) + " LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(statement) }
            try Self.bind(bindings + [.integer(Int64(max(1,min(500,request.limit)))),.integer(Int64(max(0,request.offset)))],to:statement,db:db)
            var files: [DeepFile] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
                files.append(Self.decodeFile(statement))
            }
            return InventoryPage(files:files,total:total)
        } }
    }
    /// Stream one consistent result set for background bulk/AI preparation.
    /// Does not COUNT or repeatedly walk OFFSET pages; offset/limit are ignored.
    func forEachFile(request: InventoryQuery, isCancelled: (() -> Bool)? = nil, body: (DeepFile) throws -> Void) throws {
        try read { db in try Self.withCancellation(db,isCancelled) {
            try Self.installProtections(request.protected,db:db)
            let (whereSQL,bindings) = Self.conditions(request)
            let rows = try Self.prepare(db,"SELECT " + Self.fileColumns + " FROM files f" + whereSQL + Self.order(request.sort))
            defer { sqlite3_finalize(rows) }
            try Self.bind(bindings,to:rows,db:db)
            while true {
                if isCancelled?() == true { throw CancellationError() }
                let status = sqlite3_step(rows)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
                try body(Self.decodeFile(rows))
            }
        } }
    }
    func matchingIDs(request: InventoryQuery, isCancelled: (() -> Bool)? = nil) throws -> [String] {
        try read { db in try Self.withCancellation(db,isCancelled) {
            try Self.installProtections(request.protected,db:db)
            let (whereSQL,bindings) = Self.conditions(request,allowedOnly:true)
            let statement = try Self.prepare(db,"SELECT f.id FROM files f" + whereSQL)
            defer { sqlite3_finalize(statement) }; try Self.bind(bindings,to:statement,db:db)
            var ids: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
                ids.append(Self.string(statement,0))
            }
            return ids
        } }
    }
    func selected(paths: [String], limit: Int = 100, protected: [ProtectionEntry] = [], isCancelled: (() -> Bool)? = nil) throws -> InventorySelection {
        guard !paths.isEmpty else { return InventorySelection(files: [],total:0,bytes:0) }
        return try read { db in try Self.withCancellation(db,isCancelled) {
            try Self.installProtections(protected,db:db)
            try Self.execute(db,"CREATE TEMP TABLE selected_paths(path TEXT PRIMARY KEY)")
            let insert = try Self.prepare(db,"INSERT OR IGNORE INTO selected_paths VALUES(?)")
            defer { sqlite3_finalize(insert) }
            for path in paths {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                try Self.bind([.text(path)],to:insert,db:db); try Self.done(insert,db:db)
            }
            try Self.execute(db,"BEGIN DEFERRED")
            defer { try? Self.execute(db,"ROLLBACK") }
            let (conditions,bindings) = Self.conditions(InventoryQuery(protected:protected),allowedOnly:true)
            let join = " FROM files f JOIN selected_paths s ON s.path=f.path" + conditions
            let counts = try Self.prepare(db,"SELECT COUNT(*),COALESCE(SUM(f.bytes),0)" + join)
            defer { sqlite3_finalize(counts) }; try Self.bind(bindings,to:counts,db:db)
            guard sqlite3_step(counts) == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
            let total = Int(sqlite3_column_int64(counts,0)), bytes = sqlite3_column_int64(counts,1)
            let rows = try Self.prepare(db,"SELECT " + Self.fileColumns + join + " ORDER BY f.path LIMIT ?")
            defer { sqlite3_finalize(rows) }; try Self.bind(bindings + [.integer(Int64(max(1,min(500,limit))))],to:rows,db:db)
            var files:[DeepFile] = []
            while true {
                let code = sqlite3_step(rows)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
                files.append(Self.decodeFile(rows))
            }
            return InventorySelection(files:files,total:total,bytes:bytes)
        } }
    }
    func file(path: String) throws -> DeepFile? {
        try read { db in
            let statement = try Self.prepare(db,"SELECT " + Self.fileColumns + " FROM files f WHERE path=?")
            defer { sqlite3_finalize(statement) }; try Self.bind([.text(path)],to:statement,db:db)
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
            return Self.decodeFile(statement)
        }
    }
    /// A single indexed lookup on the serialized writer connection avoids opening
    /// a new connection per file when replaying a partially completed directory.
    func entry(path: String) throws -> (DeepFile, InventorySnapshot)? {
        lock.lock(); defer { lock.unlock() }
        if cachedEntryStatement == nil {
            cachedEntryStatement = try Self.prepare(writer,"SELECT " + Self.fileColumns + ",f.identity,f.snapshot_modified,f.logical_size,f.snapshot_allowed,f.root FROM files f WHERE path=? AND identity IS NOT NULL")
        }
        let statement = cachedEntryStatement!
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try Self.bind([.text(path)],to:statement,db:writer)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(writer))) }
        return (Self.decodeFile(statement),InventorySnapshot(identity:Self.string(statement,9),modified:Date(timeIntervalSinceReferenceDate:sqlite3_column_double(statement,10)),logicalSize:Int(sqlite3_column_int64(statement,11)),allowed:sqlite3_column_int(statement,12) != 0,root:URL(fileURLWithPath:Self.string(statement,13))))
    }
    func snapshot(path: String) throws -> InventorySnapshot? {
        try read { db in
            let statement = try Self.prepare(db,"SELECT identity,snapshot_modified,logical_size,snapshot_allowed,root FROM files WHERE path=? AND identity IS NOT NULL")
            defer { sqlite3_finalize(statement) }; try Self.bind([.text(path)],to:statement,db:db)
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
            return InventorySnapshot(identity:Self.string(statement,0),modified:Date(timeIntervalSinceReferenceDate:sqlite3_column_double(statement,1)),logicalSize:Int(sqlite3_column_int64(statement,2)),allowed:sqlite3_column_int(statement,3) != 0,root:URL(fileURLWithPath:Self.string(statement,4)))
        }
    }
    func remove(paths: [String]) throws {
        try transaction(inventoryChanged:true) {
            let statement = try Self.prepare(writer,"DELETE FROM files WHERE path=?")
            defer { sqlite3_finalize(statement) }
            for path in paths { sqlite3_reset(statement); sqlite3_clear_bindings(statement); try Self.bind([.text(path)],to:statement,db:writer); try Self.done(statement,db:writer) }
        }
    }
    func issueCount() throws -> Int {
        try read { db in
            let statement = try Self.prepare(db,"SELECT COUNT(*) FROM issues"); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
            return Int(sqlite3_column_int64(statement,0))
        }
    }
    func issues(offset: Int = 0, limit: Int = 100) throws -> [DeepIssue] {
        try read { db in
            let statement = try Self.prepare(db,"SELECT path,reason FROM issues ORDER BY id LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(statement) }; try Self.bind([.integer(Int64(max(1,min(500,limit)))),.integer(Int64(max(0,offset)))],to:statement,db:db)
            var output: [DeepIssue] = []
            while sqlite3_step(statement) == SQLITE_ROW { output.append(DeepIssue(path:Self.string(statement,0),reason:Self.string(statement,1))) }
            return output
        }
    }

    /// Fresh scans deliberately replace the previous inventory. Resume preserves
    /// cached rows and replays interrupted directory jobs without duplicate files.
    @discardableResult func beginScan(roots: [URL], resume: Bool) throws -> [InventoryJob] {
        let paths = roots.map { $0.path }.sorted()
        return try transaction(inventoryChanged:true) {
            let existing = try scanStateLocked()
            if resume, let existing, existing.incomplete, existing.roots.map(\.path).sorted() == paths {
                try Self.execute(writer,"UPDATE jobs SET state=0 WHERE state=1")
                return [] // claimNextJob() streams persisted jobs, not a giant array.
            }
            try resetLocked()
            let encoded = String(data:try JSONEncoder().encode(paths),encoding:.utf8)!
            let meta = try Self.prepare(writer,"INSERT INTO scan_meta VALUES(1,?,1)")
            defer { sqlite3_finalize(meta) }; try Self.bind([.text(encoded)],to:meta,db:writer); try Self.done(meta,db:writer)
            let jobs = paths.map { InventoryJob(directory:URL(fileURLWithPath:$0),root:URL(fileURLWithPath:$0),recordFirst:true) }
            try enqueueLocked(jobs)
            return jobs
        }
    }
    private func enqueueLocked(_ jobs: [InventoryJob]) throws {
        let statement = try Self.prepare(writer,"INSERT OR IGNORE INTO jobs(directory,root,record_first,state) VALUES(?,?,?,0)")
        defer { sqlite3_finalize(statement) }
        for job in jobs {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try Self.bind([.text(job.directory.path),.text(job.root.path),.integer(job.recordFirst ? 1:0)],to:statement,db:writer); try Self.done(statement,db:writer)
        }
    }
    func enqueue(_ jobs: [InventoryJob]) throws { guard !jobs.isEmpty else { return }; try transaction { try enqueueLocked(jobs) } }
    func startJob(_ path: String) throws {
        try transaction {
            let statement = try Self.prepare(writer,"UPDATE jobs SET state=1 WHERE directory=? AND state<>2")
            defer { sqlite3_finalize(statement) }; try Self.bind([.text(path)],to:statement,db:writer); try Self.done(statement,db:writer)
        }
    }
    func finishJob(_ path: String) throws {
        try transaction {
            let statement = try Self.prepare(writer,"UPDATE jobs SET state=2 WHERE directory=?")
            defer { sqlite3_finalize(statement) }; try Self.bind([.text(path)],to:statement,db:writer); try Self.done(statement,db:writer)
        }
    }
    // Keep queue ordering aligned with jobs_pending(state,directory). Ordering
    // by rowid forces SQLite to sort every pending directory for every claim.
    static let nextPendingJobSQL = "SELECT directory,root,record_first FROM jobs WHERE state=0 ORDER BY directory LIMIT 1"
    func claimNextJob() throws -> InventoryJob? {
        try transaction {
            let statement = try Self.prepare(writer,Self.nextPendingJobSQL)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let job = InventoryJob(directory:URL(fileURLWithPath:Self.string(statement,0)),root:URL(fileURLWithPath:Self.string(statement,1)),recordFirst:sqlite3_column_int(statement,2) != 0)
            let update = try Self.prepare(writer,"UPDATE jobs SET state=1 WHERE directory=? AND state<>2")
            defer { sqlite3_finalize(update) }; try Self.bind([.text(job.directory.path)],to:update,db:writer); try Self.done(update,db:writer)
            return job
        }
    }
    /// Counts discovered directory jobs, not all directories on the computer.
    /// Newly discovered children can increase the denominator during traversal.
    func directoryProgress() throws -> (completed: Int, discovered: Int) {
        try read { db in
            let statement = try Self.prepare(db,"SELECT completed,discovered FROM job_totals WHERE singleton=1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.sqlite(String(cString:sqlite3_errmsg(db))) }
            return (completed:Int(sqlite3_column_int64(statement,0)),discovered:Int(sqlite3_column_int64(statement,1)))
        }
    }
    func pendingJobCount() throws -> Int {
        let progress = try directoryProgress()
        return progress.discovered-progress.completed
    }
    private func scanStateLocked() throws -> InventoryScanState? {
        let statement = try Self.prepare(writer,"SELECT roots,incomplete,(SELECT discovered-completed FROM job_totals WHERE singleton=1) FROM scan_meta WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let paths = try JSONDecoder().decode([String].self,from:Data(Self.string(statement,0).utf8))
        return InventoryScanState(roots:paths.map { URL(fileURLWithPath:$0) },incomplete:sqlite3_column_int(statement,1) != 0,pendingCount:Int(sqlite3_column_int64(statement,2)))
    }
    func scanState() throws -> InventoryScanState? { lock.lock(); defer { lock.unlock() }; return try scanStateLocked() }
    func finishScan(cancelled: Bool) throws {
        try transaction {
            let statement = try Self.prepare(writer,"UPDATE scan_meta SET incomplete=? WHERE singleton=1")
            defer { sqlite3_finalize(statement) }; try Self.bind([.integer(cancelled ? 1:0)],to:statement,db:writer); try Self.done(statement,db:writer)
        }
    }
}
