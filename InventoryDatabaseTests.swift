import Foundation
import SQLite3

@main struct InventoryDatabaseTests {
    static func main() throws {
        func check(_ condition: @autoclosure () throws -> Bool) throws { let passed = try condition(); precondition(passed) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-index-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("inventory.sqlite")
        let db = try InventoryDatabase(url:url)
        let folder = root.appendingPathComponent("files")
        let date = Date(timeIntervalSince1970:1_000)
        func item(_ n:Int) -> DeepFile {
            let path = folder.appendingPathComponent(n == 1 ? ".קובץ-מוסתר.txt" : "report-\(n).txt").path
            return DeepFile(id:path,path:path,title:URL(fileURLWithPath:path).lastPathComponent,category:n.isMultiple(of:2) ? "קבצים זמניים" : "מסמכים",bytes:Int64(n),modified:date.addingTimeInterval(Double(n)),isTemporary:n.isMultiple(of:2),reason:"fixture metadata",canTrash:!n.isMultiple(of:5))
        }
        // Worker batches publish file rows, coverage and child jobs atomically
        // with their parent completion, including when a write fails mid-batch.
        let batchURL = root.appendingPathComponent("batch.sqlite")
        let batchDB = try InventoryDatabase(url: batchURL)
        _ = try batchDB.beginScan(roots: [folder], resume: false)
        _ = try batchDB.claimNextJob()
        let batchChild = InventoryJob(directory: folder.appendingPathComponent("child"), root: folder, recordFirst: false)
        let batchIssue = DeepIssue(path: folder.path, reason: "fixture coverage")
        var batchHandle: OpaquePointer?
        precondition(sqlite3_open_v2(batchURL.path, &batchHandle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(batchHandle) }
        precondition(sqlite3_exec(batchHandle, "CREATE TRIGGER fail_fixture BEFORE INSERT ON files BEGIN SELECT RAISE(ABORT,'fixture failure'); END", nil, nil, nil) == SQLITE_OK)
        do {
            try batchDB.persistScanBatch(entries: [(item(1), nil)], issues: [batchIssue], jobs: [batchChild], completing: folder.path)
            preconditionFailure("batch should roll back")
        } catch {}
        try check(try batchDB.stats().count == 0)
        try check(try batchDB.issueCount() == 0)
        let rolledBack = try batchDB.directoryProgress()
        precondition(rolledBack.completed == 0 && rolledBack.discovered == 1)
        precondition(sqlite3_exec(batchHandle, "DROP TRIGGER fail_fixture", nil, nil, nil) == SQLITE_OK)
        try check(try batchDB.query(request: InventoryQuery()).total == 0)
        try batchDB.persistScanBatch(entries: [(item(1), nil)], issues: [batchIssue], jobs: [batchChild], completing: folder.path)
        try check(try batchDB.query(request: InventoryQuery()).total == 1)
        try check(try batchDB.issueCount() == 1)
        let committed = try batchDB.directoryProgress()
        precondition(committed.completed == 1 && committed.discovered == 2)
        try check(try batchDB.claimNextJob()?.directory.path == batchChild.directory.path)

        for start in stride(from:0,to:20000,by:256) {
            let rows = (start..<min(start+256,20000)).map { index -> (DeepFile,InventorySnapshot?) in
                let file = item(index)
                return (file,InventorySnapshot(identity:"file-id-\(index)",modified:file.modified,logicalSize:index,allowed:file.canTrash,root:folder))
            }
            try db.insertBatch(rows)
        }
        let stats = try db.stats()
        precondition(stats.count == 20000 && stats.bytes == 199_990_000)
        precondition(stats.temporaryCount == 10000 && stats.temporaryBytes == 99_990_000)
        precondition(stats.categories.count == 2)
        let page = try db.query(request:InventoryQuery())
        precondition(page.total == 20000 && page.files.count == 100 && page.files.first?.bytes == 19999)
        // Category browsing uses maintained totals without weakening filters.
        let categoryPage = try db.query(request:InventoryQuery(section:"מסמכים"))
        precondition(categoryPage.total == 10000 && categoryPage.files.first?.bytes == 19999)
        try check(try db.query(request:InventoryQuery(section:"זמניים")).total == 10000)
        try check(try db.query(request:InventoryQuery(section:"missing-category")).total == 0)
        try check(try db.query(request:InventoryQuery(section:"מסמכים",minimum:19990)).total == 5)
        try check(try db.query(request:InventoryQuery(section:"מסמכים",actionableOnly:true)).total == 8000)
        try check(try db.query(request:InventoryQuery(section:"זמניים",protected:[ProtectionEntry(path:item(2).path,until:nil)])).total == 9999)
        try check(try db.query(request:InventoryQuery(search:"REPORT-19999",section:"מסמכים")).total == 1)
        // The category page is delivered in index order, without sorting all
        // matching files before LIMIT can return the first page.
        var categoryHandle: OpaquePointer?
        precondition(sqlite3_open_v2(url.path,&categoryHandle,SQLITE_OPEN_READONLY,nil) == SQLITE_OK)
        var categoryPlan: OpaquePointer?
        precondition(sqlite3_prepare_v2(categoryHandle,"EXPLAIN QUERY PLAN SELECT path FROM files WHERE category='מסמכים' ORDER BY bytes DESC,path LIMIT 100",-1,&categoryPlan,nil) == SQLITE_OK)
        var categoryDetails: [String] = []
        while sqlite3_step(categoryPlan) == SQLITE_ROW { categoryDetails.append(String(cString:sqlite3_column_text(categoryPlan,3))) }
        sqlite3_finalize(categoryPlan); sqlite3_close(categoryHandle)
        precondition(categoryDetails.contains { $0.contains("files_category_size") })
        precondition(!categoryDetails.contains { $0.contains("TEMP B-TREE") })
        let limited = try db.query(request:InventoryQuery(limit:99999))
        precondition(limited.files.count == 500)
        var search = InventoryQuery(search:"קובץ מוסתר",sort:"name")
        let unicode = try db.query(request:search)
        precondition(unicode.total == 1 && unicode.files[0].title == ".קובץ-מוסתר.txt")
        search.search = "REPORT-1234 fixture"; try check(try db.query(request:search).total == 11)
        // Repeated page/sort queries share counts but writes, filters and active
        // protection expiry must never reuse an obsolete count.
        var nextPage = InventoryQuery(offset:100)
        try check(try db.query(request:nextPage).total == 20000)
        nextPage.sort = "name"
        try check(try db.query(request:nextPage).total == 20000)
        let peer = try InventoryDatabase(url:url)
        try peer.remove(paths:[item(19999).path])
        try check(try db.query(request:InventoryQuery(section:"מסמכים")).total == 9999)
        try check(try db.query(request:nextPage).total == 19999)
        try peer.insert(file:item(19999),snapshot:nil)
        try check(try db.query(request:InventoryQuery(section:"מסמכים")).total == 10000)
        try check(try db.query(request:nextPage).total == 20000)
        try check(try db.query(request:InventoryQuery(minimum:19990)).total == 10)
        var expiring = InventoryQuery(protected:[ProtectionEntry(path:item(2).path,until:Date().addingTimeInterval(0.1))])
        try check(try db.query(request:expiring).total == 19999)
        Thread.sleep(forTimeInterval:0.12)
        try check(try db.query(request:expiring).total == 20000)
        expiring.protected = [ProtectionEntry(path:item(3).path,until:nil)]
        try check(try db.query(request:expiring).total == 19999)
        // Cancel while SQLite is executing a costly substring count, rather than
        // merely discarding its result after it has blocked the UI query queue.
        var checks = 0
        do {
            _ = try db.query(request:InventoryQuery(search:"no-such-substring"),isCancelled:{ checks += 1; return checks > 3 })
            preconditionFailure("query failed to interrupt")
        } catch is CancellationError { precondition(checks > 3) }
        try check(try db.query(request:InventoryQuery()).total == 20000)
        do {
            _ = try db.matchingIDs(request:InventoryQuery(),isCancelled:{ true })
            preconditionFailure("selection failed to interrupt")
        } catch is CancellationError {}
        var streamedCount = 0
        var streamedBytes: Int64 = 0
        try db.forEachFile(request:InventoryQuery(minimum:19990,offset:100,limit:1)) { file in
            streamedCount += 1; streamedBytes += file.bytes
        }
        precondition(streamedCount == 10 && streamedBytes == (19990..<20000).reduce(Int64(0)) { $0 + Int64($1) })
        let ids = try db.matchingIDs(request:InventoryQuery())
        precondition(ids.count == 16000)
        let selected = try db.selected(paths:ids,limit:17)
        precondition(selected.total == 16000 && selected.files.count == 17)
        precondition(selected.bytes == (0..<20000).filter { !$0.isMultiple(of:5) }.reduce(Int64(0)) { $0 + Int64($1) })
        var hidden = InventoryQuery()
        hidden.protected = [ProtectionEntry(path:folder.path,until:nil)]
        try check(try db.query(request:hidden).total == 0)
        try check(try db.matchingIDs(request:hidden).isEmpty)
        hidden.protected = [ProtectionEntry(path:folder.path+"-different",until:nil)]
        try check(try db.query(request:hidden).total == 20000)
        hidden.protected = [ProtectionEntry(path:item(2).path,until:Date().addingTimeInterval(-1))]
        try check(try db.query(request:hidden).total == 20000)
        hidden.protected = [ProtectionEntry(path:item(2).path,until:nil)]
        try check(try db.query(request:hidden).total == 19999)
        try check(try db.selected(paths:[item(2).path],protected:hidden.protected).total == 0)
        try check(try db.snapshot(path:item(7).path)?.identity == "file-id-7")
        let replacement = item(7)
        try db.insert(file:replacement,snapshot:InventorySnapshot(identity:"replacement",modified:date,logicalSize:7,allowed:true,root:folder))
        try check(try db.stats().count == 20000 && db.stats().bytes == stats.bytes)
        try db.remove(paths:[item(7).path,item(8).path])
        try check(try db.stats().count == 19998)
        try db.addIssues([DeepIssue(path:"/blocked",reason:"denied"),DeepIssue(path:"/blocked",reason:"denied")])
        try check(try db.issueCount() == 1 && db.issues().count == 1)
        let concurrent = DispatchGroup()
        let concurrentLock = NSLock()
        var concurrentFailure: Error?
        let concurrentRows = (30000..<31024).map { (item($0),nil as InventorySnapshot?) }
        concurrent.enter()
        DispatchQueue.global(qos:.utility).async {
            defer { concurrent.leave() }
            do {
                for start in stride(from:0,to:concurrentRows.count,by:128) {
                    try db.insertBatch(Array(concurrentRows[start..<min(start+128,concurrentRows.count)]))
                }
            } catch { concurrentLock.lock(); concurrentFailure = error; concurrentLock.unlock() }
        }
        for _ in 0..<8 {
            let concurrentPage = try db.query(request:InventoryQuery(limit:23))
            precondition(concurrentPage.files.count == 23)
            _ = try db.stats()
        }
        concurrent.wait()
        if let concurrentFailure { throw concurrentFailure }
        try db.remove(paths:(30000..<31024).map { item($0).path })
        let reopened = try InventoryDatabase(url:url)
        try check(try reopened.stats().count == 19998)
        try check(try reopened.file(path:item(1).path)?.title == ".קובץ-מוסתר.txt")
        // Failed bulk reset must roll back data and the temporarily suspended
        // aggregate triggers. Successful reset restores them for later cleanup.
        try db.insertBatch([(item(7), nil), (item(8), nil)])
        try check(try db.stats().count == 20000)
        var resetHandle: OpaquePointer?
        precondition(sqlite3_open_v2(url.path, &resetHandle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(resetHandle) }
        precondition(sqlite3_exec(resetHandle, "CREATE TRIGGER fail_reset_fixture BEFORE DELETE ON issues BEGIN SELECT RAISE(ABORT,'reset fixture failure'); END", nil, nil, nil) == SQLITE_OK)
        do { try db.reset(); preconditionFailure("reset should roll back") } catch {}
        try check(try db.stats().count == 20000 && db.stats().bytes == stats.bytes)
        try check(try db.query(request: InventoryQuery()).total == 20000)
        try check(try db.issueCount() == 1)
        try db.remove(paths: [item(7).path])
        try check(try db.stats().count == 19999 && db.stats().bytes == stats.bytes - 7)
        try db.insert(file: item(7), snapshot: nil)
        precondition(sqlite3_exec(resetHandle, "DROP TRIGGER fail_reset_fixture", nil, nil, nil) == SQLITE_OK)
        // Fresh initialization explicitly replaces cached data; resume preserves it.
        let roots = [folder]
        let resetStarted = Date()
        _ = try db.beginScan(roots:roots,resume:false)
        print(String(format: "BENCHMARK reset 20000 files: %.4fs (local fixture wall time)", Date().timeIntervalSince(resetStarted)))
        try check(try db.stats().count == 0 && db.stats().bytes == 0 && db.stats().temporaryCount == 0 && db.stats().temporaryBytes == 0 && db.stats().categories.isEmpty)
        try check(try db.query(request: InventoryQuery()).total == 0)
        try db.insert(file: item(2), snapshot: nil)
        try check(try db.stats().count == 1 && db.stats().bytes == 2 && db.stats().temporaryCount == 1 && db.stats().temporaryBytes == 2 && db.stats().categories.count == 1)
        try db.remove(paths: [item(2).path])
        try check(try db.stats().count == 0 && db.stats().bytes == 0 && db.stats().temporaryCount == 0 && db.stats().categories.isEmpty)
        try check(try db.directoryProgress() == (completed:0,discovered:1))
        try db.enqueue([InventoryJob(directory: URL(fileURLWithPath: "/reset-delete-fixture"), root: folder, recordFirst: false)])
        try check(try db.directoryProgress() == (completed:0,discovered:2))
        precondition(sqlite3_exec(resetHandle, "DELETE FROM jobs WHERE directory='/reset-delete-fixture'", nil, nil, nil) == SQLITE_OK)
        try check(try db.directoryProgress() == (completed:0,discovered:1))
        let first = try db.claimNextJob()!
        precondition(first.directory == folder && first.recordFirst)
        try check(try db.directoryProgress() == (completed:0,discovered:1))
        let child = InventoryJob(directory:folder.appendingPathComponent("child"),root:folder,recordFirst:false)
        try db.enqueue([child,child])
        try check(try db.directoryProgress() == (completed:0,discovered:2))
        try db.insert(file:item(2),snapshot:nil)
        // Simulated crash: the in-progress root remains, and its child was committed.
        let restored = try InventoryDatabase(url:url)
        try check(try restored.scanState()?.incomplete == true)
        try check(try restored.pendingJobCount() == 2)
        try check(try restored.directoryProgress() == (completed:0,discovered:2))
        _ = try restored.beginScan(roots:roots,resume:true)
        try check(try restored.stats().count == 1)
        try check(try restored.directoryProgress() == (completed:0,discovered:2))
        var jobs:[String] = []
        while let job = try restored.claimNextJob() { jobs.append(job.directory.path); try restored.finishJob(job.directory.path) }
        precondition(Set(jobs) == [folder.path,child.directory.path])
        try restored.enqueue([child])
        try restored.finishJob(child.directory.path)
        try restored.finishJob("/missing-job")
        try check(try restored.directoryProgress() == (completed:2,discovered:2))
        try check(try restored.pendingJobCount() == 0)
        try restored.finishScan(cancelled:false)
        try check(try restored.scanState()?.incomplete == false && restored.pendingJobCount() == 0)
        // Exercise the production claim SQL against many completed/pending jobs.
        // Its plan must use indexed order, without re-sorting the pending queue.
        var handle: OpaquePointer?
        precondition(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var plan: OpaquePointer?
        precondition(sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + InventoryDatabase.nextPendingJobSQL, -1, &plan, nil) == SQLITE_OK)
        defer { sqlite3_finalize(plan) }
        var details: [String] = []
        while sqlite3_step(plan) == SQLITE_ROW {
            details.append(String(cString: sqlite3_column_text(plan, 3)))
        }
        precondition(details.contains { $0.contains("jobs_pending") })
        precondition(!details.contains { $0.contains("TEMP B-TREE") })
        var batchPlan: OpaquePointer?
        precondition(sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + InventoryDatabase.nextPendingJobsSQL, -1, &batchPlan, nil) == SQLITE_OK)
        defer { sqlite3_finalize(batchPlan) }
        precondition(sqlite3_bind_int(batchPlan, 1, 32) == SQLITE_OK)
        var batchDetails: [String] = []
        while sqlite3_step(batchPlan) == SQLITE_ROW { batchDetails.append(String(cString: sqlite3_column_text(batchPlan, 3))) }
        precondition(batchDetails.contains { $0.contains("jobs_pending") })
        precondition(!batchDetails.contains { $0.contains("TEMP B-TREE") })
        let queued = (0..<1000).map { InventoryJob(directory: folder.appendingPathComponent(String(format: "ordered-%04d", $0)), root: folder, recordFirst: false) }
        try db.enqueue(Array(queued.reversed()))
        for (index, job) in queued.enumerated() where index.isMultiple(of: 3) { try db.finishJob(job.directory.path) }
        var claimed: [String] = []
        while let job = try db.claimNextJob() { claimed.append(job.directory.path); try db.finishJob(job.directory.path) }
        precondition(claimed == queued.enumerated().filter { !$0.offset.isMultiple(of: 3) }.map { $0.element.directory.path })
        try check(try db.pendingJobCount() == 0)
        try check(try db.directoryProgress() == (completed:1002,discovered:1002))
        try db.reset()
        try check(try db.directoryProgress() == (completed:0,discovered:0))
        _ = try db.beginScan(roots:roots,resume:false)
        try check(try db.directoryProgress() == (completed:0,discovered:1))
        _ = try db.claimNextJob()
        try db.enqueue([child])
        try db.finishJob(child.directory.path)
        try db.finishScan(cancelled:true)
        _ = try reopened.beginScan(roots:roots,resume:true)
        try check(try reopened.directoryProgress() == (completed:1,discovered:2))
        try check(try reopened.scanState()?.pendingCount == 1)
        let replayedRoot = try reopened.claimNextJob()!
        precondition(replayedRoot.directory == folder)
        try reopened.finishJob(folder.path)
        try check(try db.directoryProgress() == (completed:2,discovered:2))
        // Batched claims are disjoint across connections and durably active.
        // Simulate abandoning most of a worker-local batch, then reopen/resume:
        // every unfinished directory must return exactly once, completed work never.
        let claimsURL = root.appendingPathComponent("claims.sqlite")
        let claimsDB = try InventoryDatabase(url: claimsURL)
        _ = try claimsDB.beginScan(roots: roots, resume: false)
        let claimsRoot = try claimsDB.claimNextJob()!
        try claimsDB.finishJob(claimsRoot.directory.path)
        let claimJobs = (0..<70).map { InventoryJob(directory: folder.appendingPathComponent(String(format: "batch-%03d", $0)), root: folder, recordFirst: false) }
        try claimsDB.enqueue(Array(claimJobs.reversed()))
        try check(try claimsDB.claimNextJobs(limit: 0).isEmpty)
        try check(try claimsDB.claimNextJobs(limit: -1).isEmpty)
        let firstClaims = try claimsDB.claimNextJobs(limit: 32)
        precondition(firstClaims.map(\.directory.path) == claimJobs.prefix(32).map(\.directory.path))
        let claimsPeer = try InventoryDatabase(url: claimsURL)
        let secondClaims = try claimsPeer.claimNextJobs(limit: 32)
        precondition(secondClaims.map(\.directory.path) == claimJobs.dropFirst(32).prefix(32).map(\.directory.path))
        precondition(Set(firstClaims.map(\.directory.path)).isDisjoint(with: secondClaims.map(\.directory.path)))
        for job in firstClaims.prefix(3) { try claimsDB.finishJob(job.directory.path) }
        try claimsDB.finishScan(cancelled: true)
        let claimsReopened = try InventoryDatabase(url: claimsURL)
        _ = try claimsReopened.beginScan(roots: roots, resume: true)
        var replayedClaims: [String] = []
        while true {
            let batch = try claimsReopened.claimNextJobs(limit: 32)
            if batch.isEmpty { break }
            precondition(batch.count <= 32)
            replayedClaims.append(contentsOf: batch.map(\.directory.path))
            for job in batch { try claimsReopened.finishJob(job.directory.path) }
        }
        precondition(replayedClaims == claimJobs.dropFirst(3).map(\.directory.path))
        precondition(Set(replayedClaims).count == replayedClaims.count)
        try check(try claimsReopened.directoryProgress() == (completed: 71, discovered: 71))
        // Keep even an extreme caller request bounded in memory.
        let boundedJobs = (0..<300).map { InventoryJob(directory: folder.appendingPathComponent("bounded-\($0)"), root: folder, recordFirst: false) }
        try claimsReopened.enqueue(boundedJobs)
        try check(try claimsReopened.claimNextJobs(limit: Int.max).count == 256)

        // Upgrade an inventory created before counters existed. Bootstrap counts
        // its preexisting queue once, then reopen must preserve live totals.
        let legacyURL = root.appendingPathComponent("legacy-jobs.sqlite")
        var legacyHandle: OpaquePointer?
        precondition(sqlite3_open(legacyURL.path,&legacyHandle) == SQLITE_OK)
        precondition(sqlite3_exec(legacyHandle,"CREATE TABLE jobs(directory TEXT PRIMARY KEY,root TEXT NOT NULL,record_first INTEGER NOT NULL,state INTEGER NOT NULL DEFAULT 0); INSERT INTO jobs VALUES('/pending','/',0,0),('/active','/',0,1),('/done','/',0,2);",nil,nil,nil) == SQLITE_OK)
        sqlite3_close(legacyHandle)
        let migrated = try InventoryDatabase(url:legacyURL)
        try check(try migrated.directoryProgress() == (completed:1,discovered:3))
        try migrated.finishJob("/active")
        let migratedReopened = try InventoryDatabase(url:legacyURL)
        try check(try migratedReopened.directoryProgress() == (completed:2,discovered:3))
        try migratedReopened.reset()
        try check(try migrated.directoryProgress() == (completed:0,discovered:0))
        print("PASS: 20000 disk-backed rows, bounded pages, Unicode/search/sort, protection boundaries, aggregate stats, snapshots, selection, issue deduplication, reopen, durable job resume, indexed pending-job ordering and persisted directory-progress counters")
    }
}
