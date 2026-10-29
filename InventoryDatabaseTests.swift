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
        try check(try db.query(request:nextPage).total == 19999)
        try peer.insert(file:item(19999),snapshot:nil)
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
        // Fresh initialization explicitly replaces cached data; resume preserves it.
        let roots = [folder]
        _ = try db.beginScan(roots:roots,resume:false)
        try check(try db.stats().count == 0)
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
