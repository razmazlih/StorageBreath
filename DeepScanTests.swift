import Foundation

@main struct DeepScanTests {
    private final class ReportBox {
        private let lock = NSLock()
        private var report: DeepReport?
        func set(_ value: DeepReport) { lock.lock(); report = value; lock.unlock() }
        func get() -> DeepReport? { lock.lock(); defer { lock.unlock() }; return report }
    }
    static func tryResult(_ predicate: () throws -> Bool) -> Bool { (try? predicate()) ?? false }
    static func main() throws {
        var estimate = ScanProgress(stage:"fixture",currentPath:"",inspected:0,found:0,bytes:0)
        precondition(estimate.directoryFraction == nil)
        estimate.completedDirectories = 1; estimate.discoveredDirectories = 4
        precondition(estimate.directoryPercent == 25)
        estimate.discoveredDirectories = 8
        precondition(estimate.directoryPercent == 12, "Newly discovered work changes the estimate")
        estimate.completedDirectories = 8
        precondition(estimate.directoryPercent == 100)
        estimate.completedDirectories = 9
        precondition(estimate.directoryFraction == nil)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("DeepScanFixtures-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ relative: String, _ data: Data = Data([1])) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        let hidden = try file(".hidden")
        let empty = try file("empty", Data())
        let personal = try file("personal.pdf")
        let uncertain = try file("uncertain.tmp")
        let package = try file("Example.app/Contents/fixture")
        _ = try file(".Trash/preserved")
        let link = root.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        var attempts: [String] = []
        let engine = DeepScanEngine(trashAction: { attempts.append($0.path) })
        // Synthetic paths exercise alternate/recovery-tree policy without reading it.
        precondition(engine.policySkip(URL(fileURLWithPath: "/.nofollow"), info: URLResourceValues()) != nil)
        precondition(engine.policySkip(URL(fileURLWithPath: "/.nofollow/Volumes/Recovery/example"), info: URLResourceValues())?.contains("שחזור") == true)
        precondition(engine.policySkip(URL(fileURLWithPath: "/.nofollow-other"), info: URLResourceValues()) == nil)
        var batchPaths: Set<String> = []
        var updateCount = 0
        let report = engine.scan(roots: [root], progress: { _ in updateCount += 1 }, batch: { batchPaths.formUnion($0.map(\.path)) })
        precondition(!report.cancelled)
        precondition(report.files.count == 5)
        precondition(report.files.contains { $0.path == hidden.path })
        precondition(report.files.contains { $0.path == empty.path && $0.bytes == 0 })
        precondition(report.files.contains { $0.path == package.path && !$0.canTrash })
        // The fixture itself lives in the actual user's temporary root, so these
        // files are precisely classified by location rather than filename suffix.
        precondition(report.files.contains { $0.path == uncertain.path && $0.isTemporary })
        precondition(report.issues.contains { $0.path == link.path && $0.reason.contains("סימבולי") })
        precondition(report.issues.contains { $0.path.hasSuffix(".Trash") && $0.reason.contains("המחזור") })
        precondition(batchPaths.count == report.files.count && updateCount > 0)
        let victim = report.files.first { $0.path == personal.path }!
        ProtectionStore.shared.protect(personal.path)
        defer { ProtectionStore.shared.unprotect(personal.path) }
        engine.cleanup(files: [victim]) { success, errors in precondition(success.isEmpty && errors.count == 1) }
        precondition(attempts.isEmpty)
        ProtectionStore.shared.unprotect(personal.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: personal.path)
        engine.cleanup(files: [victim]) { success, errors in precondition(success.isEmpty && errors.count == 1) }
        precondition(attempts.isEmpty)
        let fake = DeepFile(id: "/etc/passwd", path: "/etc/passwd", title: "fake", category: "test", bytes: 1, modified: Date(), isTemporary: true, reason: "", canTrash: true)
        engine.cleanup(files: [fake]) { success, errors in precondition(success.isEmpty && errors.count == 1) }
        precondition(attempts.isEmpty)
        let valid = report.files.first { $0.path == empty.path }!
        engine.cleanup(files: [valid, valid]) { success, errors in precondition(success == [empty.path] && errors.isEmpty) }
        precondition(attempts == [empty.path])
        precondition(fm.fileExists(atPath: empty.path)) // injected action never deletes
        engine.cleanup(files: [valid]) { success, errors in precondition(success.isEmpty && errors.count == 1) }
        precondition(attempts.count == 1)
        let cancelled = engine.scan(roots: [root], progress: { _ in engine.cancel() })
        precondition(cancelled.cancelled)
        precondition(cancelled.issues.contains { $0.reason.contains("בוטלה") })
        var cancellationAttempts: [String] = []
        let cleanupEngine = DeepScanEngine(trashAction: { cancellationAttempts.append($0.path) })
        let cancellable = cleanupEngine.scan(roots: [root]).files.filter(\.canTrash)
        precondition(cancellable.count >= 2)
        var finalProcessed = -1
        cleanupEngine.cleanup(files: cancellable, progress: { done, _, _ in
            finalProcessed = done
            if done == 1 { cleanupEngine.cancelCleanup() }
        }) { success, errors in
            precondition(success.count == 1 && errors.count == cancellable.count - 1)
        }
        precondition(cancellationAttempts.count == 1 && finalProcessed == 1)
        // Inventory a downloaded ubiquitous regular file without entering its cloud directory.
        let source = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("DeepScanTests.swift")
        if (try? source.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            let cloudReport = engine.scan(roots: [source])
            precondition(cloudReport.files.count == 1)
            precondition(!cloudReport.files[0].canTrash && cloudReport.files[0].reason.contains("ענן"))
        }
        // Pure classification fixtures avoid touching personal/cloud directories.
        let uncertainClass = engine.classify(URL(fileURLWithPath: "/Users/fixture/unfinished.tmp"))
        precondition(uncertainClass.0 == "חשוד כזמני" && !uncertainClass.1 && uncertainClass.2.contains("בלבד"))
        let personalClass = engine.classify(URL(fileURLWithPath: "/Users/fixture/document.pdf"))
        precondition(personalClass.0 == "מסמכים" && !personalClass.1)
        for path in ["/Users/fixture/project/__pycache__/x.pyc", "/Users/fixture/.pytest_cache/x", "/Users/fixture/.mypy_cache/x", "/Users/fixture/.ruff_cache/x", "/Users/fixture/.npm/_cacache/x", "/Users/fixture/.gradle/caches/x"] {
            precondition(engine.classify(URL(fileURLWithPath: path)).1)
        }
        for path in ["/Users/fixture/project/node_modules/package/index.js", "/Users/fixture/project/build/result", "/Users/fixture/not__pycache__/x", "/Users/fixture/.cache/x", "/Library/Caches/vendor/x", "/Users/fixture/project/__pycache__/important.sqlite", "/Users/fixture/project/__pycache__/source.py", "/Users/fixture/.cache/huggingface/hub/blobs/model", "/Users/fixture/.ollama/models/blobs/sha256-abcd", "/Users/fixture/.cache/torch/hub/weights", "/Users/fixture/project/model.safetensors", "/Users/fixture/project/model.gguf", "/Users/fixture/download.part", "/Users/fixture/download.crdownload", "/Users/fixture/download.download", "/Users/fixture/unknown.temp"] {
            precondition(!engine.classify(URL(fileURLWithPath: path)).1)
        }
        precondition(engine.classify(URL(fileURLWithPath:"/Users/fixture/project/__pycache__/legacy.pyo")).1)
        precondition(engine.classify(URL(fileURLWithPath:"/Users/fixture/.cache/huggingface/model")).0 == "מודלים ונתוני AI")
        precondition(engine.classify(URL(fileURLWithPath:"/Users/fixture/download.part")).2.contains("פעילה"))
        // Specific exclusions remain conservative even under an actual temp root.
        precondition(!engine.classify(root.appendingPathComponent("active.crdownload")).1)
        precondition(!engine.classify(root.appendingPathComponent(".cache/huggingface/weights")).1)
        precondition(ScanPerformance.background.workerCount == 1)
        precondition(ScanPerformance.balanced.workerCount <= 2)
        precondition(ScanPerformance.background.qos.qosClass == .background)
        precondition(ScanPerformance.balanced.qos.qosClass == .utility)
        precondition(ScanPerformance.turbo.qos.qosClass == .userInitiated)
        precondition(ScanPerformance.turbo.workerCount == max(1, ProcessInfo.processInfo.activeProcessorCount))
        // Thousands of tiny entries spread across directories expose lost-work,
        // queue termination, callback ordering, and duplicate-inventory bugs.
        for directory in 0..<36 {
            for index in 0..<64 {
                _ = try file("benchmark/dir-\(directory)/file-\(index)", index.isMultiple(of: 8) ? Data() : Data([1]))
            }
        }
        let serial = DeepScanEngine(workerOverride: 1).scan(roots: [root], performance: .balanced)
        var delivered: Set<String> = []
        var lastInspected = -1
        let callbackGuard = NSLock()
        let parallel = DeepScanEngine().scan(roots: [root], performance: .turbo, progress: { value in
            precondition(callbackGuard.try(), "overlapping callbacks")
            defer { callbackGuard.unlock() }
            precondition(value.inspected >= lastInspected)
            lastInspected = value.inspected
        }, batch: { chunk in
            precondition(callbackGuard.try(), "overlapping progress/batch callbacks")
            defer { callbackGuard.unlock() }
            for item in chunk { precondition(delivered.insert(item.path).inserted) }
        })
        let serialPaths = Set(serial.files.map(\.path))
        let parallelPaths = Set(parallel.files.map(\.path))
        precondition(serialPaths == parallelPaths && delivered == parallelPaths)
        precondition(serial.inspected == parallel.inspected)
        precondition(serial.files.reduce(Int64(0)) { $0 + $1.bytes } == parallel.files.reduce(Int64(0)) { $0 + $1.bytes })
        precondition(Set(serial.issues.map(\.id)) == Set(parallel.issues.map(\.id)))
        precondition(serial.workers == 1 && parallel.workers == ScanPerformance.turbo.workerCount)
        precondition(!parallel.cancelled && parallel.files.count >= 2304)
        let background = DeepScanEngine().scan(roots: [root])
        precondition(background.workers == 1 && !background.cancelled)
        precondition(Set(background.files.map(\.path)) == serialPaths)
        precondition(background.inspected == serial.inspected)
        precondition(Set(background.issues.map(\.id)) == Set(serial.issues.map(\.id)))
        // Pause is a condition wait, and cancel must wake every paused worker.
        for shouldCancel in [false, true] {
            let controlled = DeepScanEngine()
            let pausedSignal = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let result = ReportBox()
            DispatchQueue.global(qos: .background).async {
                var once = false
                let report = controlled.scan(roots: [root], performance: .turbo, progress: { _ in
                    if !once { once = true; controlled.pause(); pausedSignal.signal() }
                })
                result.set(report)
                finished.signal()
            }
            precondition(pausedSignal.wait(timeout: .now() + 5) == .success)
            precondition(controlled.isPaused)
            precondition(finished.wait(timeout: .now() + 0.05) == .timedOut)
            if shouldCancel { controlled.cancel() } else { controlled.resume() }
            precondition(finished.wait(timeout: .now() + 10) == .success, "paused workers failed to wake")
            precondition(!controlled.isPaused)
            let report = result.get()!
            precondition(report.cancelled == shouldCancel)
            if !shouldCancel { precondition(Set(report.files.map(\.path)) == serialPaths) }
        }
        let dbURL = root.deletingLastPathComponent().appendingPathComponent("DeepDiskFixture-" + UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: dbURL.path + suffix) } }
        let database = try InventoryDatabase(url: dbURL)
        var diskBatches = 0
        let diskEngine = DeepScanEngine(database: database)
        var diskProgress: [ScanProgress] = []
        let diskReport = diskEngine.scan(roots: [root], performance: .turbo, progress:{ diskProgress.append($0) }, batch: { _ in diskBatches += 1 })
        precondition(diskProgress.first?.directoryPercent == 0 && diskProgress.last?.directoryPercent == 100)
        precondition(diskProgress.allSatisfy { ($0.completedDirectories ?? -1) <= ($0.discoveredDirectories ?? -2) })
        precondition(diskReport.files.isEmpty && diskReport.issues.isEmpty && !diskReport.cancelled && diskBatches == 0)
        precondition(tryResult { try database.stats().count == serial.files.count })
        var diskPaths: Set<String> = []
        for offset in stride(from: 0, to: serial.files.count, by: 500) {
            var request = InventoryQuery(); request.offset = offset; request.limit = 500
            diskPaths.formUnion(try database.query(request: request).files.map(\.path))
        }
        precondition(diskPaths == serialPaths, "streaming disk traversal must include package descendants")
        precondition(tryResult { try database.pendingJobCount() == 0 })
        // A cancelled run leaves durable queued/active directory jobs. A new
        // engine/connection resumes them without retaining or duplicating files.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { diskEngine.cancel() }
        var partialProgress: [ScanProgress] = []
        let partial = diskEngine.scan(roots: [root], performance: .background,progress:{ partialProgress.append($0) })
        precondition((partialProgress.last?.directoryFraction ?? 1) < 1)
        precondition(partial.cancelled)
        precondition(tryResult { try database.scanState()?.incomplete == true })
        precondition(tryResult { try database.pendingJobCount() > 0 })
        let reopened = try InventoryDatabase(url: dbURL)
        var resumedProgress: [ScanProgress] = []
        let resumed = DeepScanEngine(database: reopened).scan(roots: [root], performance: .turbo, resume: true,progress:{ resumedProgress.append($0) })
        precondition(resumedProgress.first?.completedDirectories == partialProgress.last?.completedDirectories)
        precondition(resumedProgress.first?.discoveredDirectories == partialProgress.last?.discoveredDirectories)
        precondition(resumedProgress.last?.directoryPercent == 100)
        precondition(!resumed.cancelled && resumed.files.isEmpty)
        precondition(tryResult { try reopened.stats().count == serial.files.count })
        precondition(tryResult { try reopened.pendingJobCount() == 0 })
        // Simulate a crash after claiming a durable job, then replay safely.
        let unchangedSnapshot = try reopened.snapshot(path:empty.path)!
        let staleClassification = DeepFile(id:empty.path,path:empty.path,title:empty.lastPathComponent,category:"legacy classification",bytes:0,modified:unchangedSnapshot.modified,isTemporary:false,reason:"old classification policy",canTrash:true)
        _ = try reopened.beginScan(roots: [root], resume: false)
        _ = try reopened.claimNextJob()
        try reopened.insert(file:staleClassification,snapshot:unchangedSnapshot)
        try reopened.finishScan(cancelled: true)
        _ = DeepScanEngine(database: reopened).scan(roots: [root], performance: .turbo, resume: true)
        precondition(tryResult { try reopened.stats().count == serial.files.count })
        let persisted = try reopened.file(path: empty.path)!
        precondition(persisted.category == engine.classify(empty).0 && persisted.isTemporary == engine.classify(empty).1 && !persisted.reason.contains("old classification"))
        var persistedAttempts: [String] = []
        DeepScanEngine(trashAction: { persistedAttempts.append($0.path) }, database: reopened).cleanup(files: [persisted]) { success, errors in
            precondition(success == [empty.path] && errors.isEmpty)
        }
        precondition(persistedAttempts == [empty.path] && fm.fileExists(atPath: empty.path))
        precondition(tryResult { try reopened.file(path: empty.path) == nil })
        // Preflight exclusions are reported and never inventoried.
        let excluded = DeepScanEngine(database: reopened).scan(roots: [root], performance: .turbo, excludedPaths: [root.appendingPathComponent("benchmark").path])
        precondition(!excluded.cancelled)
        precondition(tryResult { try reopened.stats().count == 5 })
        precondition(tryResult { try reopened.issues(limit: 100).contains { $0.reason.contains("הרשאות") } })
        let immediate = DeepScanEngine()
        let cancelledParallel = immediate.scan(roots: [root], performance: .turbo, progress: { _ in immediate.cancel() })
        precondition(cancelledParallel.cancelled)
        print(String(format: "BENCHMARK %d files: serial 1 worker %.3fs; turbo %d workers %.3fs (fixture wall times, no speedup guarantee)", parallel.files.count, serial.elapsed, parallel.workers, parallel.elapsed))
        print("PASS: hidden/zero/package inventory; explicit skip reasons; batched progress; cancellation; protection/mutation/forged guards; injected cleanup/cancellation; cloud file metadata; background parity/QoS; pause/resume/cancel wake; disk parity/resume/crash replay; persisted cleanup; permission exclusions; deduplication; no real deletion")
    }
}
