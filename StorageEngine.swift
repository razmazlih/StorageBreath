import Foundation
import AppKit

enum CleanupRisk: String { case safe, review }
struct ScanItem: Identifiable {
    let id: String
    let path: String
    let title: String
    let category: String
    let bytes: Int64
    let risk: CleanupRisk
}
struct ScanProgress {
    let stage: String
    let currentPath: String
    let inspected: Int
    let found: Int
    let bytes: Int64
    var completedDirectories: Int? = nil
    var discoveredDirectories: Int? = nil
    /// A fraction of discovered directory work, never filesystem-wide coverage.
    var directoryFraction: Double? {
        guard let completedDirectories, let discoveredDirectories,
              discoveredDirectories > 0, completedDirectories >= 0,
              completedDirectories <= discoveredDirectories else { return nil }
        return Double(completedDirectories) / Double(discoveredDirectories)
    }
    var directoryPercent: Int? { directoryFraction.map { Int(($0 * 100).rounded(.down)) } }
}
struct ScanReport {
    let items: [ScanItem]
    let skipped: Int
    let inspected: Int
    var limited: Bool = false
}

/// Reads file metadata only. It never opens file contents or empties the Trash.
final class StorageEngine {
    private let fm = FileManager.default
    private let lock = NSLock()
    private var approved: [String: Date] = [:]
    private let temporaryRoot: URL
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }
    private var scanHome = URL(fileURLWithPath: NSHomeDirectory())
    private let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey, .contentAccessDateKey]

    func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, progress: ((String) -> Void)? = nil, details: ((ScanProgress) -> Void)? = nil) -> ScanReport {
        var items: [ScanItem] = []
        var snapshots: [String: Date] = [:]
        var skipped = 0
        var inspected = 0
        var limited = false
        var stage = "מתחיל סריקה"
        var lastUpdate = Date.distantPast
        var candidateBytes: Int64 = 0
        func emit(_ path: String = "", force: Bool = false) {
            guard force || Date().timeIntervalSince(lastUpdate) >= 0.2 else { return }
            lastUpdate = Date()
            details?(ScanProgress(stage: stage, currentPath: path, inspected: inspected, found: items.count, bytes: candidateBytes))
        }
        func setStage(_ value: String) { stage = value; progress?(value); emit(force: true) }
        let root = home.standardizedFileURL
        let start = Date()
        let limit = 180_000
        var categoryStart = Date()
        var categoryInspected = 0
        func resetBudget() { categoryStart = Date(); categoryInspected = inspected }
        func exhausted() -> Bool {
            let hit = inspected >= limit || Date().timeIntervalSince(start) >= 75 || inspected - categoryInspected >= 18_000 || Date().timeIntervalSince(categoryStart) >= 8
            if hit { limited = true }
            return hit
        }
        func metadata(_ url: URL) -> URLResourceValues? {
            inspected += 1
            emit(url.path)
            guard !exhausted() else { skipped += 1; return nil }
            do { return try url.resourceValues(forKeys: keys) }
            catch { skipped += 1; return nil }
        }
        func size(_ url: URL) -> Int64? {
            guard let info = metadata(url), info.isSymbolicLink != true, info.isUbiquitousItem != true else { skipped += 1; return nil }
            if info.isRegularFile == true { return Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? 0) }
            var complete = true
            guard info.isDirectory == true, let walk = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in skipped += 1; complete = false; return true }) else { return nil }
            var total: Int64 = 0
            while let file = walk.nextObject() as? URL {
                if exhausted() { skipped += 1; complete = false; break }
                guard let value = metadata(file) else { complete = false; walk.skipDescendants(); continue }
                if value.isSymbolicLink == true || value.isUbiquitousItem == true { walk.skipDescendants(); skipped += 1; complete = false; continue }
                if value.isRegularFile == true { total += Int64(value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? 0) }
            }
            return complete ? total : nil
        }
        func add(_ url: URL, category: String, risk: CleanupRisk, minimum: Int64) {
            guard !containsSymlink(url, home: root), let info = metadata(url), info.isSymbolicLink != true, info.isUbiquitousItem != true else { return }
            guard let bytes = size(url), bytes >= minimum, let modified = info.contentModificationDate else { return }
            let path = url.standardizedFileURL.path
            items.append(ScanItem(id: path, path: path, title: url.lastPathComponent, category: category, bytes: bytes, risk: risk))
            snapshots[path] = modified
            candidateBytes += bytes
        }
        // Only regenerable build output is considered a low-risk candidate. Caches may
        // contain offline data or currently-open files, so they require review.
        let folders: [(String, String, CleanupRisk)] = [
            ("Library/Caches", "מטמוני יישומים", .review),
            ("Library/Logs", "יומני פעילות", .review),
            ("Library/Developer/Xcode/DerivedData", "תוצרי בנייה של Xcode", .safe),
            ("Library/Developer/Xcode/Archives", "ארכיוני Xcode", .review)
        ]
        for (relative, category, risk) in folders {
            resetBudget()
            let folder = root.appendingPathComponent(relative)
            setStage(category)
            guard !containsSymlink(folder, home: root) else { skipped += 1; continue }
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: []) else { skipped += 1; continue }
            for child in children {
                if exhausted() { skipped += 1; break }
                add(child, category: category, risk: risk, minimum: 5 * 1_024 * 1_024)
            }
        }
        // Scan top-level Downloads entries so each result is independently reviewable.
        resetBudget()
        let downloads = root.appendingPathComponent("Downloads")
        setStage("הורדות")
        if !containsSymlink(downloads, home: root), let children = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for child in children {
                if exhausted() { skipped += 1; break }
                add(child, category: "הורדות", risk: .review, minimum: 20 * 1_024 * 1_024)
            }
        } else { skipped += 1 }
        for name in ["Desktop", "Documents", "Movies"] {
            resetBudget()
            setStage("קבצים גדולים: \(name)")
            let folder = root.appendingPathComponent(name)
            guard !containsSymlink(folder, home: root), let walk = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true }) else { skipped += 1; continue }
            while let url = walk.nextObject() as? URL {
                if exhausted() { skipped += 1; break }
                guard let info = metadata(url) else { continue }
                if info.isSymbolicLink == true || info.isUbiquitousItem == true { walk.skipDescendants(); skipped += 1; continue }
                // Avoid developer dependencies and cloud-provider roots.
                if info.isDirectory == true && ["node_modules", ".git", "CloudStorage", "Mobile Documents", "build", "dist"].contains(url.lastPathComponent) { walk.skipDescendants(); continue }
                if info.isRegularFile == true, Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? 0) >= 500 * 1_024 * 1_024 {
                    add(url, category: "קבצים גדולים", risk: .review, minimum: 500 * 1_024 * 1_024)
                }
            }
        }
        resetBudget()
        setStage("קבצים זמניים ישנים")
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        if (root.path == fm.homeDirectoryForCurrentUser.standardizedFileURL.path || temporaryRoot.path.hasPrefix(root.path + "/")), let children = try? fm.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for child in children {
                if exhausted() { skipped += 1; break }
                guard !containsSymlink(child, home: temporaryRoot),
                      let info = metadata(child), let modified = info.contentModificationDate,
                      modified <= cutoff else { continue }
                guard let bytes = oldTemporarySize(child, cutoff: cutoff, maxEntries: 18_000 - (inspected - categoryInspected), deadline: min(start.addingTimeInterval(75), categoryStart.addingTimeInterval(8)), counted: { inspected += $0; emit(child.path) }), bytes >= 1_024 * 1_024 else { skipped += 1; _ = exhausted(); continue }
                let path = child.standardizedFileURL.path
                items.append(ScanItem(id: path, path: path, title: child.lastPathComponent, category: "קבצים זמניים ישנים", bytes: bytes, risk: .review))
                snapshots[path] = modified
                candidateBytes += bytes
            }
        } else { skipped += 1 }
        lock.lock(); approved = snapshots; scanHome = root; lock.unlock()
        emit(force: true)
        return ScanReport(items: items.sorted { $0.bytes > $1.bytes }, skipped: skipped, inspected: inspected, limited: limited)
    }

    private func containsSymlink(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/") else { return true }
        var current = url.standardizedFileURL
        while current.path != home.path {
            guard let attributes = try? fm.attributesOfItem(atPath: current.path) else { return true }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    /// Fail closed for stale temporary directories: every entry must still be old,
    /// local, ordinary, and within the user's private temporary root.
    private func oldTemporarySize(_ url: URL, cutoff: Date, maxEntries: Int, deadline: Date, counted: (Int) -> Void = { _ in }) -> Int64? {
        guard maxEntries > 0, !containsSymlink(url, home: temporaryRoot) else { return nil }
        var count = 0
        var complete = true
        var total: Int64 = 0
        func inspect(_ entry: URL) -> Bool {
            count += 1; counted(1)
            guard count <= maxEntries, Date() < deadline,
                  let info = try? entry.resourceValues(forKeys: keys),
                  info.isSymbolicLink != true, info.isUbiquitousItem != true,
                  info.isRegularFile == true || info.isDirectory == true,
                  let modified = info.contentModificationDate, modified <= cutoff,
                  (info.creationDate ?? modified) <= cutoff,
                  (info.contentAccessDate ?? modified) <= cutoff else { return false }
            if info.isRegularFile == true { total += Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? 0) }
            return true
        }
        guard inspect(url) else { return nil }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return total }
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in complete = false; return false }) else { return nil }
        while let entry = walk.nextObject() as? URL {
            if !inspect(entry) { complete = false; break }
        }
        return complete ? total : nil
    }

    func trash(_ items: [ScanItem], completion: @escaping ([String]) -> Void) {
        lock.lock(); let snapshot = approved; let home = scanHome; lock.unlock()
        var errors: [String] = []
        var urls: [URL] = []
        for item in items {
            guard !ProtectionStore.shared.isProtected(item.path) else {
                errors.append("\(item.title): מוגן מניקוי. יש להסיר את ההגנה לפני הפעולה.")
                continue
            }
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            guard url.path == item.path, snapshot[item.path] != nil,
                  (!containsSymlink(url, home: home) || !containsSymlink(url, home: temporaryRoot)),
                  let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isUbiquitousItemKey]),
                  info.isUbiquitousItem != true,
                  info.contentModificationDate == snapshot[item.path] else {
                errors.append("\(item.title): השתנה מאז הסריקה או שאינו מותר לניקוי. יש לסרוק מחדש.")
                continue
            }
            if url.path.hasPrefix(temporaryRoot.path + "/") && oldTemporarySize(url, cutoff: Date().addingTimeInterval(-7 * 24 * 60 * 60), maxEntries: 18_000, deadline: Date().addingTimeInterval(8)) == nil {
                errors.append("\(item.title): קובץ זמני פעיל, חדש או לא נגיש; הפעולה בוטלה.")
                continue
            }
            urls.append(url)
        }
        guard !urls.isEmpty else { completion(errors); return }
        let finalURLs = urls.filter { url in
            if ProtectionStore.shared.isProtected(url.path) {
                errors.append("\(url.lastPathComponent): מוגן מניקוי.")
                return false
            }
            if url.path.hasPrefix(temporaryRoot.path + "/") && oldTemporarySize(url, cutoff: Date().addingTimeInterval(-7 * 24 * 60 * 60), maxEntries: 18_000, deadline: Date().addingTimeInterval(8)) == nil {
                errors.append("\(url.lastPathComponent): הזמניים השתנו; יש לסרוק מחדש.")
                return false
            }
            return true
        }
        guard !finalURLs.isEmpty else { completion(errors); return }
        let protectedErrors = errors
        NSWorkspace.shared.recycle(finalURLs) { _, error in
            completion(protectedErrors + (error.map { ["ההעברה לסל לא הושלמה: \($0.localizedDescription)"] } ?? []))
        }
    }
}
