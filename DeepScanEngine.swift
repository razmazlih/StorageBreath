import Foundation
import Darwin

enum ScanPerformance: String, CaseIterable, Identifiable {
    case background, balanced, turbo
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .background: return "רקע שקט"
        case .balanced: return "מאוזן"
        case .turbo: return "טורבו — כל הליבות"
        }
    }
    var workerCount: Int {
        let processors = max(1, ProcessInfo.processInfo.activeProcessorCount)
        switch self {
        case .background: return 1
        case .balanced: return min(2, processors)
        case .turbo: return processors
        }
    }
    var qos: DispatchQoS {
        switch self {
        case .background: return .background
        case .balanced: return .utility
        case .turbo: return .userInitiated
        }
    }
}

struct DeepFile: Identifiable {
    let id: String
    let path: String
    let title: String
    let category: String
    let bytes: Int64
    let modified: Date
    let isTemporary: Bool
    let reason: String
    let canTrash: Bool
}
struct DeepIssue: Identifiable {
    let path: String
    let reason: String
    var id: String { path + "\n" + reason }
}
struct DeepReport {
    let files: [DeepFile]
    let issues: [DeepIssue]
    let inspected: Int
    let cancelled: Bool
    var workers: Int = 1
    var elapsed: TimeInterval = 0
}

/// Uncapped metadata-only file inventory. Every omission is recorded; file contents
/// are never opened. Cleanup revalidates each selected file immediately before Trash.
final class DeepScanEngine {
    private static func canonicalLocation(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return url.standardizedFileURL
    }
    static var defaultRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser,
         canonicalLocation(FileManager.default.temporaryDirectory)]
    }
    private struct Snapshot {
        let identity: String
        let modified: Date
        let logicalSize: Int
        let allowed: Bool
        let root: URL
    }
    private struct DirectoryWork {
        let directory: URL
        let root: URL
        let recordFirst: Bool
    }
    private final class ScanState {
        let condition = NSCondition()
        let callbackLock = NSLock()
        var work: [DirectoryWork] = []
        var active = 0
        var completedDirectories = 0
        var discoveredDirectories = 0
        var files: [DeepFile] = []
        var issues: [DeepIssue] = []
        var snapshots: [String: Snapshot] = [:]
        var pending: [DeepFile] = []
        var inspected = 0
        var bytes: Int64 = 0
        var lastUpdate = Date.distantPast
        var seenPaths: Set<String> = []
        var seenDirectories: Set<String> = []
    }
    private let workerOverride: Int?
    private let fm = FileManager.default
    private let stateLock = NSCondition()
    private let scanLock = NSLock()
    private var stop = false
    private var paused = false
    private var activeScan: ScanState?
    private var activeDatabase: InventoryDatabase?
    private var activeExclusions: [String] = []
    private var cleanupStop = false
    private var cleanupActive = false
    private var known: [String: Snapshot] = [:]
    private let trashAction: (URL) throws -> Void
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    private let temporary = DeepScanEngine.canonicalLocation(FileManager.default.temporaryDirectory)
    private let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        .fileResourceIdentifierKey, .volumeIsLocalKey, .volumeIdentifierKey
    ]
    init(trashAction: ((URL) throws -> Void)? = nil, workerOverride: Int? = nil, database: InventoryDatabase? = nil) {
        self.activeDatabase = database
        self.workerOverride = workerOverride.map { max(1, $0) }
        self.trashAction = trashAction ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        }
    }
    func cancel() {
        stateLock.lock(); stop = true; let scan = activeScan; stateLock.broadcast(); stateLock.unlock()
        // Do not hold the control lock while taking the aggregation lock.
        scan?.condition.lock(); scan?.condition.broadcast(); scan?.condition.unlock()
    }
    func pause() { stateLock.lock(); paused = true; stateLock.broadcast(); stateLock.unlock() }
    func resume() { stateLock.lock(); paused = false; stateLock.broadcast(); stateLock.unlock() }
    var isPaused: Bool { stateLock.lock(); defer { stateLock.unlock() }; return paused }
    private func awaitScanPermission(delay: TimeInterval = 0) -> Bool {
        let deadline = Date().addingTimeInterval(delay)
        stateLock.lock(); defer { stateLock.unlock() }
        while !stop {
            if paused { stateLock.wait(); continue }
            if Date() < deadline { _ = stateLock.wait(until: deadline); continue }
            return true
        }
        return false
    }
    func cancelCleanup() { stateLock.lock(); cleanupStop = true; stateLock.unlock() }
    private var cleanupCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return cleanupStop }
    private var cancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stop }
    private func inside(_ path: String, _ root: String) -> Bool {
        path == root || root == "/" || path.hasPrefix(root + "/")
    }
    private func under(_ path: String, _ root: String) -> Bool { path != root && inside(path, root) }
    private func hasLinkAncestor(_ url: URL) -> Bool {
        var cursor = Self.canonicalLocation(url)
        while cursor.path != "/" {
            guard let attr = try? fm.attributesOfItem(atPath: cursor.path),
                  attr[.type] as? FileAttributeType != .typeSymbolicLink else { return true }
            cursor.deleteLastPathComponent()
        }
        return false
    }
    private func cloudPath(_ path: String) -> Bool {
        inside(path, home.appendingPathComponent("Library/Mobile Documents").path)
        || inside(path, home.appendingPathComponent("Library/CloudStorage").path)
    }
    private func systemPath(_ path: String) -> Bool {
        ["/System", "/usr", "/bin", "/sbin", "/Library", "/private/etc", "/private/var/db", "/private/var/root", "/Applications"].contains { inside(path, $0) }
    }
    private func packagePath(_ path: String) -> Bool {
        // Inventory package contents, but never offer individual package internals
        // as cleanup candidates; that could corrupt an application or user document.
        let suffixes: Set<String> = ["app", "framework", "bundle", "plugin", "kext", "photoslibrary", "photolibrary", "pages", "numbers", "key", "rtfd", "playground", "xcworkspace", "xcodeproj"]
        return URL(fileURLWithPath: path).pathComponents.contains {
            suffixes.contains(($0 as NSString).pathExtension.lowercased())
        }
    }
    func policySkip(_ url: URL, info: URLResourceValues) -> String? {
        let path = url.path
        if path == "/.nofollow" || path.hasPrefix("/.nofollow/") {
            return "תצוגת מערכת חלופית או שחזור — מוחרגת כדי למנוע סריקה כפולה של אמצעי אחסון"
        }
        if info.isSymbolicLink == true { return "קישור סימבולי — אין מעקב אל היעד" }
        if inside(path, home.appendingPathComponent("Library/CloudStorage").path) { return "ספק אחסון ענן חיצוני — מוחרג כדי למנוע הורדה אוטומטית" }
        if info.isDirectory == true && info.isUbiquitousItem == true
            && info.ubiquitousItemDownloadingStatus != .current
            && info.ubiquitousItemDownloadingStatus != .downloaded {
            return "תיקיית iCloud אינה זמינה מקומית — אין הורדה אוטומטית"
        }
        if url.lastPathComponent == ".Trash" || url.lastPathComponent == ".Trashes" { return "סל המחזור מוחרג כדי לשמור אפשרות שחזור" }
        if ["/dev", "/proc", "/net", "/Network", "/private/var/run", "/Volumes", "/System/Volumes"].contains(path) { return "מערכת וירטואלית או קבצי מערכת פעילים" }
        if info.volumeIsLocal == false { return "אמצעי אחסון מרוחק — מוחרג מסריקה מקומית" }
        return nil
    }
    private func identity(_ values: URLResourceValues) -> String? {
        values.fileResourceIdentifier.map { String(describing: values.volumeIdentifier) + ":" + String(describing: $0) }
    }
    private func owned(_ url: URL) -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }
    private func allowed(_ url: URL, root: URL, verifyAncestors: Bool = true) -> Bool {
        let path = url.path
        guard under(path, root.path), !systemPath(path), !cloudPath(path), !packagePath(path),
              !path.contains("/.Trash/"), !path.contains("/.Trashes/"),
              owned(url), (!verifyAncestors || !hasLinkAncestor(url)) else { return false }
        // Full-Mac scans do not authorize cleanup of arbitrary OS-managed roots.
        return under(path, home.path) || under(path, temporary.path)
            || (root.path != "/" && !systemPath(root.path) && owned(root))
    }
    func classify(_ url: URL) -> (String, Bool, String) {
        let path = url.path
        let components = url.pathComponents.map { $0.lowercased() }
        let ext = url.pathExtension.lowercased()
        // A cache-shaped location does not make downloaded model assets disposable.
        // Run these exclusions before the broader temporary/cache-root rules.
        let modelExtensions: Set<String> = ["safetensors", "gguf", "ggml", "ckpt", "pt", "pth", "onnx", "tflite", "mlmodel", "mlpackage"]
        if components.contains(where: { ["huggingface", ".huggingface", ".ollama", "ollama", "torch", "transformers", "sentence_transformers", "sentence-transformers", "modelscope"].contains($0) })
            || modelExtensions.contains(ext) {
            return ("מודלים ונתוני AI", false, "מודל או נתוני כלי AI; עשויים להיות נחוצים ויקרים להורדה מחדש או לעבודה לא מקוונת — אינם מסווגים כזמניים")
        }
        if ["part", "download", "crdownload"].contains(ext) {
            return ("הורדות חלקיות", false, "הורדה חלקית או פעילה; אין הוכחה שהסתיימה או שהקובץ אינו בשימוש — לבדיקה ידנית בלבד")
        }
        if components.contains("__pycache__") {
            if ["pyc", "pyo"].contains(ext) {
                return ("מטמוני פיתוח", true, "קוד Python מהודר בתוך __pycache__; ניתן ליצור מחדש מקוד המקור, ויש לבדוק שאינו בשימוש")
            }
            return ("מטמוני פיתוח", false, "קובץ לא מוכר בתוך __pycache__; המיקום לבדו אינו מוכיח שזהו מטמון שניתן לשחזר")
        }
        let cacheNames: Set<String> = [".pytest_cache", ".mypy_cache", ".ruff_cache"]
        let developerCache = components.contains { cacheNames.contains($0) }
            || path.contains("/.npm/_cacache/") || path.contains("/.gradle/caches/")
        if developerCache {
            return ("מטמוני פיתוח", true, "נתיב מטמון מוכר של כלי פיתוח; יש לבדוק שאינו בשימוש לפני ניקוי")
        }
        if components.contains(".cache") {
            return ("מטמונים לבדיקה", false, "תיקיית .cache כללית עשויה להכיל מידע נחוץ או נתונים לעבודה לא מקוונת; אינה הוכחה לקובץ זמני")
        }
        if path.contains("/Library/Caches/") {
            return ("מטמוני יישומים", false, "מטמון יישום עשוי להכיל מידע נחוץ לעבודה לא מקוונת או להיות בשימוש; נדרשת בדיקה ידנית")
        }
        let knownRoots = [
            (home.appendingPathComponent("Library/Logs").path, "יומני פעילות", "יומן פעילות; עשוי לסייע באבחון תקלות"),
            (home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path, "תוצרי בנייה", "תוצר בנייה של Xcode שניתן ליצור מחדש"),
            (temporary.path, "קבצים זמניים", "תיקייה זמנית של המשתמש; קובץ עשוי להיות בשימוש כרגע")
        ]
        for (root, category, reason) in knownRoots where under(path, root) { return (category, true, reason) }
        if ["tmp", "temp"].contains(ext) {
            return ("חשוד כזמני", false, "סיומת זמנית בלבד; אין הוכחה שהקובץ מיותר או אינו בשימוש — לבדיקה ידנית בלבד")
        }
        let groups: [(Set<String>, String)] = [
            (["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "raw", "svg"], "תמונות"),
            (["mov", "mp4", "mkv", "avi", "m4v", "webm"], "וידאו"),
            (["mp3", "m4a", "wav", "flac", "aiff"], "שמע"),
            (["zip", "gz", "tar", "7z", "rar", "dmg", "pkg"], "ארכיונים והתקנות"),
            (["pdf", "doc", "docx", "txt", "md", "csv", "xlsx"], "מסמכים")
        ]
        for (extensions, category) in groups where extensions.contains(ext) { return (category, false, "קובץ אישי — נדרשת בדיקה לפני העברה לסל") }
        return ("קבצים אחרים", false, "לא זוהה כזמני; נדרשת בדיקה לפני העברה לסל")
    }

    func scan(roots: [URL] = DeepScanEngine.defaultRoots, performance: ScanPerformance = .background, database: InventoryDatabase? = nil, resume: Bool = false, excludedPaths: [String] = [], progress: ((ScanProgress) -> Void)? = nil, batch: (([DeepFile]) -> Void)? = nil) -> DeepReport {
        stateLock.lock(); let selectedDatabase = database ?? activeDatabase; stateLock.unlock()
        if let selectedDatabase { return scanOnDisk(roots: roots, performance: performance, database: selectedDatabase, resume: resume, excludedPaths: excludedPaths, progress: progress) }
        scanLock.lock(); defer { scanLock.unlock() }
        let started = Date()
        let excluded = excludedPaths.map { Self.canonicalLocation(URL(fileURLWithPath: $0)).path }
        let workers = workerOverride ?? performance.workerCount
        let state = ScanState()
        let cachedKeys = Array(keys)
        stateLock.lock(); stop = false; paused = false; known = [:]; activeScan = state; activeExclusions = excluded; stateLock.unlock()
        func issue(_ url: URL, _ reason: String) {
            state.condition.lock()
            state.issues.append(DeepIssue(path: url.path, reason: reason))
            state.condition.unlock()
        }
        // Callbacks are serialized but never execute while the aggregation lock is
        // held, so a progress callback may safely cancel the scan.
        func emit(_ path: String, force: Bool = false) {
            if force { state.callbackLock.lock() }
            else if !state.callbackLock.try() { return }
            defer { state.callbackLock.unlock() }
            state.condition.lock()
            guard force || Date().timeIntervalSince(state.lastUpdate) >= (performance == .background ? 1.5 : 0.5) else { state.condition.unlock(); return }
            state.lastUpdate = Date()
            let update = ScanProgress(stage: "סריקה מקבילית · \(workers) עובדים", currentPath: path, inspected: state.inspected, found: state.files.count, bytes: state.bytes, completedDirectories:state.completedDirectories, discoveredDirectories:state.discoveredDirectories)
            let chunk = state.pending
            state.pending.removeAll(keepingCapacity: true)
            state.condition.unlock()
            progress?(update)
            if !chunk.isEmpty { batch?(chunk) }
        }
        func record(_ url: URL, root: URL) -> Bool {
            if excluded.contains(where: { inside(url.path, $0) }) {
                issue(url, "מוחרג לפי הגדרת ההרשאות לפני הסריקה")
                return false
            }
            guard awaitScanPermission() else { return false }
            state.condition.lock()
            guard state.seenPaths.insert(url.path).inserted else { state.condition.unlock(); return false }
            state.inspected += 1
            let inspected = state.inspected
            state.condition.unlock()
            if performance == .background && inspected.isMultiple(of: 64) {
                let thermal = ProcessInfo.processInfo.thermalState
                let delay: TimeInterval = thermal == .serious || thermal == .critical ? 0.1 : 0.02
                guard awaitScanPermission(delay: delay) else { return false }
            }
            emit(url.path)
            guard !cancelled else { return false }
            do {
                let info = try url.resourceValues(forKeys: keys)
                if let reason = policySkip(url, info: info) { issue(url, reason); return false }
                if info.isDirectory == true {
                    if let key = identity(info) {
                        state.condition.lock()
                        let fresh = state.seenDirectories.insert(key).inserted
                        state.condition.unlock()
                        if !fresh { issue(url, "תיקייה כבר נסרקה דרך נתיב אחר"); return false }
                    }
                    return true
                }
                guard info.isRegularFile == true else { issue(url, "פריט מיוחד שאינו קובץ רגיל"); return false }
                let classification = classify(url)
                let fileIdentity = identity(info)
                let modified = info.contentModificationDate ?? .distantPast
                let isCloud = info.isUbiquitousItem == true || cloudPath(url.path)
                let permitted = !isCloud && info.contentModificationDate != nil && fileIdentity != nil && info.fileSize != nil && allowed(url, root: root, verifyAncestors: false)
                if info.contentModificationDate == nil || fileIdentity == nil || info.fileSize == nil { issue(url, "מטא־נתונים חסרים; הקובץ מוצג ללא אפשרות ניקוי") }
                let item = DeepFile(id: url.path, path: url.path, title: url.lastPathComponent,
                                    category: classification.0, bytes: info.ubiquitousItemDownloadingStatus == .notDownloaded ? 0 : Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0),
                                    modified: modified, isTemporary: classification.1, reason: classification.2 + (isCloud ? " · קובץ ענן לקריאה בלבד; מוצג נפח מקומי ללא הורדה" : ""), canTrash: permitted)
                state.condition.lock()
                state.files.append(item); state.pending.append(item); state.bytes += item.bytes
                if let key = fileIdentity, let date = info.contentModificationDate, let size = info.fileSize {
                    state.snapshots[url.path] = Snapshot(identity: key, modified: date, logicalSize: size, allowed: permitted, root: root)
                }
                state.condition.unlock()
                return false
            } catch { issue(url, "אין גישה למטא־נתונים: \(error.localizedDescription)"); return false }
        }
        let normalized = roots.map { Self.canonicalLocation($0) }.sorted { $0.path.count < $1.path.count }
        var selected: [URL] = []
        for root in normalized {
            if selected.contains(where: { inside(root.path, $0.path) }) { issue(root, "תיקייה כבר כלולה בשורש סריקה אחר") }
            else { selected.append(root) }
        }
        for root in selected {
            if cancelled { break }
            if excluded.contains(where: { inside(root.path, $0) }) { issue(root, "מוחרג לפי הגדרת ההרשאות לפני הסריקה"); continue }
            guard !hasLinkAncestor(root) else { issue(root, "שורש הסריקה מכיל קישור סימבולי או אינו נגיש"); continue }
            state.work.append(DirectoryWork(directory: root, root: root, recordFirst: true))
            state.discoveredDirectories += 1
        }
        emit(selected.first?.path ?? "", force: true)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "StoragePilot.deepScan", qos: performance.qos, attributes: .concurrent)
        for _ in 0..<workers {
            group.enter()
            queue.async {
                defer { group.leave() }
                while !self.cancelled {
                    state.condition.lock()
                    while state.work.isEmpty && state.active > 0 && !self.cancelled {
                        state.condition.wait()
                    }
                    guard !self.cancelled, let task = state.work.popLast() else { state.condition.unlock(); break }
                    state.active += 1
                    state.condition.unlock()
                    autoreleasepool {
                        let traverse = !task.recordFirst || record(task.directory, root: task.root)
                        if traverse && self.awaitScanPermission() {
                            do {
                                // Explicit traversal includes packages and hidden entries.
                                let children = try self.fm.contentsOfDirectory(at: task.directory, includingPropertiesForKeys: cachedKeys, options: [])
                                for child in children {
                                    if self.cancelled { break }
                                    if record(child, root: task.root) {
                                        state.condition.lock()
                                        state.work.append(DirectoryWork(directory: child, root: task.root, recordFirst: false))
                                        state.discoveredDirectories += 1
                                        state.condition.broadcast()
                                        state.condition.unlock()
                                    }
                                }
                            } catch { issue(task.directory, "לא ניתן לסרוק: \(error.localizedDescription)") }
                        }
                    }
                    state.condition.lock(); state.active -= 1; if !self.cancelled { state.completedDirectories += 1 }; state.condition.broadcast(); state.condition.unlock()
                }
            }
        }
        group.wait()
        let wasCancelled = cancelled
        if wasCancelled { issue(selected.first ?? URL(fileURLWithPath: "/"), "הסריקה בוטלה; התוצאות חלקיות") }
        stateLock.lock(); known = state.snapshots; activeScan = nil; paused = false; stateLock.unlock()
        emit("", force: true)
        return DeepReport(files: state.files, issues: state.issues, inspected: state.inspected, cancelled: wasCancelled, workers: workers, elapsed: Date().timeIntervalSince(started))
    }

    /// Disk inventory keeps only a small worker-local write batch in memory. The
    /// durable pending/active job table is also the work queue and resume journal.
    private func scanOnDisk(roots: [URL], performance: ScanPerformance, database: InventoryDatabase, resume: Bool, excludedPaths: [String], progress: ((ScanProgress) -> Void)?) -> DeepReport {
        scanLock.lock(); defer { scanLock.unlock() }
        let started = Date()
        let excluded = excludedPaths.map { Self.canonicalLocation(URL(fileURLWithPath: $0)).path }
        let workers = workerOverride ?? performance.workerCount
        let state = ScanState()
        let cachedKeys = Array(keys)
        stateLock.lock(); stop = false; paused = false; known = [:]; activeDatabase = database; activeScan = state; activeExclusions = excluded; stateLock.unlock()
        var selected: [URL] = []
        for root in roots.map({ Self.canonicalLocation($0) }).sorted(by: { $0.path.count < $1.path.count }) {
            if !selected.contains(where: { inside(root.path, $0.path) }) { selected.append(root) }
        }
        func fail(_ path: String, _ error: Error) {
            state.condition.lock()
            if state.issues.isEmpty { state.issues.append(DeepIssue(path: path, reason: "לא ניתן לשמור את אינדקס הסריקה: \(error.localizedDescription)")) }
            state.condition.unlock()
            self.cancel()
        }
        func issue(_ url: URL, _ reason: String) {
            do { try database.addIssues([DeepIssue(path: url.path, reason: reason)]) }
            catch { fail(url.path, error) }
        }
        func emit(_ path: String, force: Bool = false) {
            if force { state.callbackLock.lock() } else if !state.callbackLock.try() { return }
            defer { state.callbackLock.unlock() }
            state.condition.lock()
            guard force || Date().timeIntervalSince(state.lastUpdate) >= (performance == .background ? 1.5 : 0.5) else { state.condition.unlock(); return }
            state.lastUpdate = Date()
            let inspected = state.inspected
            state.condition.unlock()
            do {
                let stats = try database.stats()
                let directories = try database.directoryProgress()
                progress?(ScanProgress(stage: "סריקה נשמרת בדיסק · \(workers) עובדים", currentPath: path, inspected: inspected, found: stats.count, bytes: stats.bytes, completedDirectories:directories.completed, discoveredDirectories:directories.discovered))
            } catch { fail(path, error) }
        }
        do {
            _ = try database.beginScan(roots: selected, resume: resume)
            let stats = try database.stats()
            state.inspected = stats.count
        } catch { fail(selected.first?.path ?? "", error) }
        emit(selected.first?.path ?? "", force: true)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "StoragePilot.diskScan", qos: performance.qos, attributes: .concurrent)
        for _ in 0..<workers {
            group.enter()
            queue.async {
                defer { group.leave() }
                var entries: [(DeepFile, InventorySnapshot?)] = []
                entries.reserveCapacity(256)
                var localIssues: [DeepIssue] = []
                localIssues.reserveCapacity(64)
                var pendingJobs: [InventoryJob] = []
                pendingJobs.reserveCapacity(64)
                func flushJobs() {
                    guard !pendingJobs.isEmpty else { return }
                    do {
                        try database.enqueue(pendingJobs)
                        pendingJobs.removeAll(keepingCapacity:true)
                        state.condition.lock(); state.condition.broadcast(); state.condition.unlock()
                    } catch { fail(pendingJobs.first?.directory.path ?? "",error) }
                }
                func flushIssues() {
                    guard !localIssues.isEmpty else { return }
                    do { try database.addIssues(localIssues); localIssues.removeAll(keepingCapacity: true) }
                    catch { fail(localIssues.first?.path ?? "", error); localIssues.removeAll(keepingCapacity: true) }
                }
                func workerIssue(_ url: URL, _ reason: String) {
                    localIssues.append(DeepIssue(path: url.path, reason: reason))
                    if localIssues.count >= 64 { flushIssues() }
                }
                func flush() {
                    // Children are durable before their parent can be retired,
                    // including cancellation replay of an unfinished directory.
                    flushJobs()
                    flushIssues()
                    guard !entries.isEmpty else { return }
                    do { try database.insertBatch(entries); entries.removeAll(keepingCapacity: true) }
                    catch { fail(entries.first?.0.path ?? "", error); entries.removeAll(keepingCapacity: true) }
                }
                func record(_ url: URL, root: URL) -> Bool {
                    if excluded.contains(where: { self.inside(url.path, $0) }) {
                        workerIssue(url, "מוחרג לפי הגדרת ההרשאות לפני הסריקה")
                        return false
                    }
                    if [database.url.path, database.url.path + "-wal", database.url.path + "-shm"].contains(url.path) {
                        workerIssue(url, "אינדקס הסריקה הפעיל — מוחרג מניקוי ומסריקה")
                        return false
                    }
                    guard self.awaitScanPermission() else { return false }
                    state.condition.lock(); state.inspected += 1; let inspected = state.inspected; state.condition.unlock()
                    if performance == .background && inspected.isMultiple(of: 64) {
                        let thermal = ProcessInfo.processInfo.thermalState
                        guard self.awaitScanPermission(delay: thermal == .serious || thermal == .critical ? 0.1 : 0.02) else { return false }
                    }
                    emit(url.path)
                    guard !self.cancelled else { return false }
                    do {
                        let info = try url.resourceValues(forKeys: self.keys)
                        if let reason = self.policySkip(url, info: info) { workerIssue(url, reason); return false }
                        if info.isDirectory == true { return true }
                        guard info.isRegularFile == true else { workerIssue(url, "פריט מיוחד שאינו קובץ רגיל"); return false }
                        let identity = self.identity(info)
                        let isCloud = info.isUbiquitousItem == true || self.cloudPath(url.path)
                        let allowed = !isCloud && identity != nil && info.fileSize != nil && info.contentModificationDate != nil && self.allowed(url, root: root, verifyAncestors: false)
                        // Classification is cheap and policy can change between app
                        // versions. Replayed rows always use the current rules;
                        // untouched completed directories need an explicit full refresh.
                        let classification = self.classify(url)
                        let reason = classification.2 + (isCloud ? " · קובץ ענן לקריאה בלבד; מוצג נפח מקומי ללא הורדה" : "")
                        let item = DeepFile(id: url.path, path: url.path, title: url.lastPathComponent, category: classification.0,
                                            bytes: info.ubiquitousItemDownloadingStatus == .notDownloaded ? 0 : Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0),
                                            modified: info.contentModificationDate ?? .distantPast, isTemporary: classification.1,
                                            reason: reason, canTrash: allowed)
                        var snapshot: InventorySnapshot?
                        if let identity, let modified = info.contentModificationDate, let size = info.fileSize {
                            snapshot = InventorySnapshot(identity: identity, modified: modified, logicalSize: size, allowed: allowed, root: root)
                        } else { workerIssue(url, "מטא־נתונים חסרים; הקובץ מוצג ללא אפשרות ניקוי") }
                        entries.append((item, snapshot))
                        if entries.count >= 256 { flush() }
                        return false
                    } catch { workerIssue(url, "אין גישה למטא־נתונים: \(error.localizedDescription)"); return false }
                }
                while self.awaitScanPermission() {
                    state.condition.lock()
                    var task: InventoryJob?
                    while !self.cancelled {
                        do { task = try database.claimNextJob() }
                        catch { state.condition.unlock(); fail("", error); state.condition.lock(); break }
                        if task != nil || state.active == 0 { break }
                        state.condition.wait()
                    }
                    guard !self.cancelled, let task else { state.condition.unlock(); break }
                    state.active += 1
                    state.condition.unlock()
                    autoreleasepool {
                        if excluded.contains(where: { self.inside(task.directory.path, $0) }) { workerIssue(task.directory, "מוחרג לפי הגדרת ההרשאות לפני הסריקה") }
                        else if self.hasLinkAncestor(task.directory) { workerIssue(task.directory, "נתיב התיקייה השתנה, מכיל קישור או אינו נגיש") }
                        else if record(task.directory, root: task.root) && self.awaitScanPermission() {
                            // Shallow streaming enumeration avoids retaining a huge
                            // flat directory's URLs and prefetched metadata at once.
                            var enumerationFailed = false
                            if let walk = self.fm.enumerator(at: task.directory, includingPropertiesForKeys: cachedKeys, options: [.skipsSubdirectoryDescendants], errorHandler: { url, error in
                                workerIssue(url, "לא ניתן לסרוק: \(error.localizedDescription)"); enumerationFailed = true; return false
                            }) {
                                while !self.cancelled {
                                    let more = autoreleasepool { () -> Bool in
                                        guard let child = walk.nextObject() as? URL else { return false }
                                        if record(child, root: task.root) {
                                            pendingJobs.append(InventoryJob(directory:child,root:task.root,recordFirst:false))
                                            if pendingJobs.count >= 64 { flushJobs() }
                                        }
                                        return true
                                    }
                                    if !more { break }
                                }
                            } else { enumerationFailed = true }
                            if enumerationFailed { workerIssue(task.directory, "לא ניתן להשלים את קריאת התיקייה") }
                        }
                        flush()
                        // Persist children and file rows before retiring their
                        // parent job. Cancel/crash leaves it replayable on resume.
                        if !self.cancelled {
                            do { try database.finishJob(task.directory.path) }
                            catch { fail(task.directory.path, error) }
                        }
                    }
                    state.condition.lock(); state.active -= 1; state.condition.broadcast(); state.condition.unlock()
                }
                flush()
            }
        }
        group.wait()
        let wasCancelled = cancelled
        if wasCancelled { issue(selected.first ?? URL(fileURLWithPath: "/"), "הסריקה בוטלה; ניתן להמשיך מהאינדקס השמור") }
        do { try database.finishScan(cancelled: wasCancelled) } catch { fail("", error) }
        stateLock.lock(); activeScan = nil; paused = false; stateLock.unlock()
        emit("", force: true)
        return DeepReport(files: [], issues: state.issues, inspected: state.inspected, cancelled: wasCancelled || cancelled, workers: workers, elapsed: Date().timeIntervalSince(started))
    }

    func cleanup(files: [DeepFile], progress: ((Int, Int, String) -> Void)? = nil, completion: ([String], [String]) -> Void) {
        stateLock.lock()
        guard !cleanupActive else {
            stateLock.unlock()
            completion([], files.map { "\($0.path): פעולת ניקוי אחרת כבר מתבצעת" })
            return
        }
        cleanupActive = true; cleanupStop = false
        let snapshots = known
        let database = activeDatabase
        let excluded = activeExclusions
        stateLock.unlock()
        var successes: [String] = []
        var errors: [String] = []
        var seen: Set<String> = []
        let requested = files.filter { seen.insert($0.path).inserted }
        var processed = 0
        for (index, item) in requested.enumerated() {
            progress?(processed, requested.count, item.path)
            if cleanupCancelled {
                errors.append(contentsOf: requested[index...].map { "\($0.path): הניקוי בוטל לפני ביצוע הפעולה" })
                break
            }
            do {
                guard !ProtectionStore.shared.isProtected(item.path) else { throw CleanupFailure.message("מוגן מניקוי") }
                guard !excluded.contains(where: { inside(item.path, $0) }) else { throw CleanupFailure.message("מוחרג לפי הגדרת ההרשאות") }
                let url = Self.canonicalLocation(URL(fileURLWithPath: item.path))
                var prior = snapshots[item.path]
                if prior == nil, let stored = try database?.snapshot(path: item.path) {
                    prior = Snapshot(identity: stored.identity, modified: stored.modified, logicalSize: stored.logicalSize, allowed: stored.allowed, root: stored.root)
                }
                guard url.path == item.path, let prior, prior.allowed,
                      allowed(url, root: prior.root) else { throw CleanupFailure.message("הקובץ אינו מאושר לניקוי; יש לסרוק מחדש") }
                let current = try url.resourceValues(forKeys: keys)
                guard current.isRegularFile == true, current.isDirectory != true,
                      current.isSymbolicLink != true, current.isUbiquitousItem != true,
                      policySkip(url, info: current) == nil,
                      identity(current) == prior.identity,
                      current.contentModificationDate == prior.modified,
                      current.fileSize == prior.logicalSize else { throw CleanupFailure.message("הקובץ השתנה מאז הסריקה; יש לסרוק מחדש") }
                guard !ProtectionStore.shared.isProtected(item.path) else { throw CleanupFailure.message("מוגן מניקוי") }
                try trashAction(url)
                successes.append(item.path)
                if let database { try database.remove(paths: [item.path]) }
                stateLock.lock(); known.removeValue(forKey: item.path); stateLock.unlock()
            } catch { errors.append("\(item.path): \(error.localizedDescription)") }
            processed += 1
            progress?(processed, requested.count, item.path)
        }
        stateLock.lock(); cleanupActive = false; stateLock.unlock()
        progress?(processed, requested.count, "")
        completion(successes, errors)
    }
    private enum CleanupFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
