import Foundation
import AppKit

struct CloudItem: Identifiable {
    let id: String
    let path: String
    let title: String
    let logicalBytes: Int64
    let localBytes: Int64
    let canEvict: Bool
    var canDelete: Bool = true
    var modified: Date = .distantPast
}
struct CloudScanIssue: Identifiable {
    let path: String
    let reason: String
    var id: String { path + "\n" + reason }
}
struct CloudReport {
    let items: [CloudItem]
    let skipped: Int
    var limited: Bool = false
    var cancelled: Bool = false
    var issues: [CloudScanIssue] = []
}

/// Inventories accessible iCloud app containers, including hidden files and package contents.
/// Directory listings may require iCloud metadata/network access. File contents are
/// never opened and startDownloadingUbiquitousItem is never called.
final class CloudEngine {
    private static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return url.standardizedFileURL
    }
    private struct Snapshot {
        let modified: Date
        let identifier: String
        let logicalBytes: Int
        let actionable: Bool
    }
    private let fm = FileManager.default
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var stop = false
    private var snapshots: [String: Snapshot] = [:]
    private let root: URL
    private let actionRoot: URL
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .fileResourceIdentifierKey, .volumeIdentifierKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemDownloadingErrorKey
    ]
    /// Root injection supports isolated fixtures; production inventories all local iCloud containers.
    init(root: URL? = nil) {
        self.root = Self.canonical((root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true))
            .resolvingSymlinksInPath())
        // App-owned containers are visible for review, but cleanup remains limited
        // to ordinary iCloud Drive documents where the user manages files directly.
        self.actionRoot = root == nil ? self.root.appendingPathComponent("com~apple~CloudDocs", isDirectory: true) : self.root
    }
    func cancel() { lock.lock(); stop = true; lock.unlock() }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stop }

    private func safePath(_ url: URL, verifyAncestors: Bool = true) -> Bool {
        let normalized = Self.canonical(url)
        guard normalized.path.hasPrefix(root.path + "/"), normalized.path == url.path else { return false }
        guard verifyAncestors else { return true }
        var cursor = normalized
        while true {
            guard let attrs = try? fm.attributesOfItem(atPath: cursor.path),
                  attrs[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
            if cursor.path == "/" { return true }
            cursor.deleteLastPathComponent()
        }
    }
    private func withinActionRoot(_ url: URL) -> Bool {
        url.path.hasPrefix(actionRoot.path + "/")
    }
    private func snapshot(_ values: URLResourceValues, actionable: Bool) -> Snapshot? {
        guard let date = values.contentModificationDate,
              let identity = values.fileResourceIdentifier,
              let size = values.fileSize else { return nil }
        return Snapshot(modified: date,
                        identifier: String(describing: values.volumeIdentifier) + ":" + String(describing: identity),
                        logicalBytes: size, actionable: actionable)
    }
    private func evictable(_ values: URLResourceValues) -> Bool {
        let status = values.ubiquitousItemDownloadingStatus
        return values.isUbiquitousItem == true
            && values.ubiquitousItemIsUploaded == true
            && values.ubiquitousItemIsUploading != true
            && values.ubiquitousItemIsDownloading != true
            && values.ubiquitousItemUploadingError == nil
            && values.ubiquitousItemDownloadingError == nil
            && (status == .current || status == .downloaded)
    }
    private func packageAncestor(_ url: URL) -> Bool {
        var cursor = url
        while cursor.path != root.path {
            guard let values = try? cursor.resourceValues(forKeys: [.isPackageKey]) else { return true }
            if values.isPackage == true { return true }
            cursor.deleteLastPathComponent()
            guard cursor.path == root.path || cursor.path.hasPrefix(root.path + "/") else { return true }
        }
        return false
    }

    func scan(excludingPaths: [String] = [], progress: ((ScanProgress) -> Void)? = nil) -> CloudReport {
        scanLock.lock(); defer { scanLock.unlock() }
        lock.lock(); stop = false; snapshots = [:]; lock.unlock()
        let excluded = excludingPaths.map { Self.canonical(URL(fileURLWithPath: $0)).path }
        func isExcluded(_ url: URL) -> Bool {
            excluded.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
        }
        var collected: [CloudItem] = []
        var fresh: [String: Snapshot] = [:]
        var issues: [CloudScanIssue] = []
        var inspected = 0
        var localTotal: Int64 = 0
        var completedDirectories = 0, discoveredDirectories = 0
        var lastProgress = Date.distantPast
        func issue(_ url: URL, _ reason: String) { issues.append(CloudScanIssue(path: url.path, reason: reason)) }
        func emit(_ path: String, force: Bool = false) {
            guard force || Date().timeIntervalSince(lastProgress) >= 0.3 else { return }
            lastProgress = Date()
            progress?(ScanProgress(stage: "סריקת iCloud עמוקה · מטא־נתונים בלבד", currentPath: path,
                                   inspected: inspected, found: collected.count, bytes: localTotal, completedDirectories:completedDirectories, discoveredDirectories:discoveredDirectories))
        }
        emit(root.path, force: true)
        if isExcluded(root) {
            issue(root, "הוחרג בהכנת הרשאות — לא נבדק")
            return CloudReport(items: [], skipped: issues.count, issues: issues)
        }
        do {
            let attributes = try fm.attributesOfItem(atPath: root.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  Self.canonical(root.resolvingSymlinksInPath()).path == root.path else {
                issue(root, "שורש iCloud אינו תיקייה מקומית נגישה")
                return CloudReport(items: [], skipped: issues.count, cancelled: cancelled, issues: issues)
            }
        } catch {
            issue(root, "אין גישה ל־iCloud Drive: \(error.localizedDescription)")
            return CloudReport(items: [], skipped: issues.count, cancelled: cancelled, issues: issues)
        }
        let rootIsPackage = (try? root.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        var directories: [(URL, Bool)] = [(root, rootIsPackage)]
        discoveredDirectories = 1
        var seen: Set<String> = []
        while !cancelled, let (directory, insidePackage) = directories.popLast() {
            emit(directory.path)
            if isExcluded(directory) {
                issue(directory, "הוחרג בהכנת הרשאות — לא נבדק")
                completedDirectories += 1
                continue
            }
            do {
                // options:[] is intentional: hidden items and package descendants
                // must not disappear silently from a deep cloud inventory.
                let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [])
                for url in children {
                    if cancelled { break }
                    let path = Self.canonical(url).path
                    guard seen.insert(path).inserted else { continue }
                    if isExcluded(url) { issue(url, "הוחרג בהכנת הרשאות — לא נבדק"); continue }
                    inspected += 1; emit(path)
                    guard safePath(url, verifyAncestors: false) else { issue(url, "נתיב אינו בתוך שורש iCloud"); continue }
                    do {
                        let values = try url.resourceValues(forKeys: keys)
                        if values.isSymbolicLink == true { issue(url, "קישור סימבולי — אין מעקב ליעד"); continue }
                        if url.lastPathComponent == ".Trash" || url.lastPathComponent == ".Trashes" {
                            issue(url, "סל מחזור — מוחרג כדי לשמור אפשרות שחזור"); continue
                        }
                        let packaged = insidePackage || values.isPackage == true
                        if values.isDirectory == true {
                            directories.append((url, packaged))
                            discoveredDirectories += 1
                            continue
                        }
                        guard values.isRegularFile == true else { issue(url, "פריט מיוחד שאינו קובץ רגיל"); continue }
                        let confirmedCloud = values.isUbiquitousItem == true
                        let allowedLocation = withinActionRoot(url)
                        let identity = snapshot(values, actionable: !packaged && confirmedCloud && allowedLocation)
                        let actionable = !packaged && confirmedCloud && allowedLocation && identity != nil
                        if !confirmedCloud { issue(url, "אין מטא־נתונים המאשרים שזהו קובץ iCloud — מוצג לעיון בלבד") }
                        if !allowedLocation { issue(url, "מכל נתוני יישום — מוצג לעיון בלבד; ניקוי זמין מתוך iCloud Drive בלבד") }
                        let local: Int64 = values.ubiquitousItemDownloadingStatus == .notDownloaded ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                        collected.append(CloudItem(id: path, path: path, title: url.lastPathComponent,
                                                   logicalBytes: Int64(values.fileSize ?? 0), localBytes: local,
                                                   canEvict: actionable && evictable(values) && local > 0,
                                                   canDelete: actionable, modified: values.contentModificationDate ?? .distantPast))
                        localTotal += local
                        if let identity { fresh[path] = identity }
                        if identity == nil { issue(url, "מטא־נתונים חסרים — מוצג לעיון בלבד") }
                        if packaged { issue(url, "תוכן חבילה — מוצג לעיון בלבד כדי למנוע פגיעה במסמך או ביישום") }
                    } catch { issue(url, "אין גישה למטא־נתונים: \(error.localizedDescription)") }
                }
            } catch { issue(directory, "לא ניתן לרשום את תוכן התיקייה: \(error.localizedDescription)") }
            if !cancelled { completedDirectories += 1 }
        }
        let wasCancelled = cancelled
        if wasCancelled { issue(root, "הסריקה נעצרה; התוצאות כוללות רק פריטים שנבדקו") }
        lock.lock(); snapshots = fresh; lock.unlock()
        emit(root.path, force: true)
        return CloudReport(items: collected.sorted {
            if $0.localBytes != $1.localBytes { return $0.localBytes > $1.localBytes }
            if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
            return $0.path < $1.path
        }, skipped: issues.count, cancelled: wasCancelled, issues: issues)
    }

    func act(items: [CloudItem], evict: Bool, completion: @escaping ([String]) -> Void) {
        lock.lock(); let known = snapshots; lock.unlock()
        var errors: [String] = []
        var validated: [URL] = []
        var seen: Set<String> = []
        for item in items where seen.insert(item.path).inserted {
            guard !ProtectionStore.shared.isProtected(item.path) else {
                errors.append("\(item.title): מוגן מניקוי. יש להסיר את ההגנה לפני הפעולה.")
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            guard let old = known[item.path], old.actionable, withinActionRoot(url), safePath(url), !packageAncestor(url),
                  let current = try? url.resourceValues(forKeys: keys),
                  current.isRegularFile == true, current.isDirectory != true,
                  current.isPackage != true, current.isUbiquitousItem == true,
                  let now = snapshot(current, actionable: true), old.identifier == now.identifier,
                  old.modified == now.modified, old.logicalBytes == now.logicalBytes else {
                errors.append("\(item.title): הקובץ השתנה, הוא תוכן חבילה או אינו מאושר לפעולה. יש לסרוק מחדש.")
                continue
            }
            if evict {
                guard evictable(current) else {
                    errors.append("\(item.title): לא ניתן לפנות מקומית לפני שההעלאה ל־iCloud הושלמה וללא שגיאות סנכרון.")
                    continue
                }
                do {
                    guard !ProtectionStore.shared.isProtected(url.path) else {
                        errors.append("\(item.title): מוגן מניקוי."); continue
                    }
                    try fm.evictUbiquitousItem(at: url)
                } catch { errors.append("\(item.title): \(error.localizedDescription)") }
            } else { validated.append(url) }
        }
        guard !evict, !validated.isEmpty else { completion(errors); return }
        let finalURLs = validated.filter { url in
            guard !ProtectionStore.shared.isProtected(url.path), withinActionRoot(url), safePath(url), !packageAncestor(url) else {
                errors.append("\(url.lastPathComponent): מוגן או אינו מאושר לניקוי."); return false
            }
            return true
        }
        guard !finalURLs.isEmpty else { completion(errors); return }
        let previous = errors
        NSWorkspace.shared.recycle(finalURLs) { _, error in
            completion(previous + (error.map { ["ההעברה לסל לא הושלמה: \($0.localizedDescription)"] } ?? []))
        }
    }
}

/// Explanations based only on inventory metadata. A candidate is a prompt for
/// manual review, never evidence that a file is unwanted or permission to act.
struct CloudSuggestion {
    let title: String
    let reason: String
    let uncertainty: String
    let question: String
    let isCandidate: Bool
    var isCandidateForCloudDeletion: Bool = false

    static func evaluate(_ item: CloudItem, now: Date = Date()) -> CloudSuggestion {
        guard item.canDelete else {
            return CloudSuggestion(title: "לעיון בלבד", reason: "הפריט אינו מאושר למחיקה בסריקה הנוכחית; ייתכן שהוא תוכן חבילה או שחסרים פרטי זיהוי.",
                uncertainty: "אין להסיק מכך אם הקובץ נחוץ. סריקה חדשה עשויה לעדכן את זמינות הפעולה.",
                question: "האם תרצו להציג את הפריט ב־Finder כדי לבדוק למה הוא שייך?", isCandidate: false)
        }
        let url = URL(fileURLWithPath: item.path)
        let ext = url.pathExtension.lowercased()
        let knownDate = item.modified != .distantPast && item.modified <= now
        let old = knownDate && now.timeIntervalSince(item.modified) >= 180 * 86400
        let temporary = ["tmp", "temp", "part", "crdownload", "download"].contains(ext)
        if temporary {
            return CloudSuggestion(title: "קובץ זמני או הורדה חלקית לבדיקה", reason: "סיומת .\(ext) עשויה לציין קובץ עבודה זמני או הורדה שלא הושלמה.",
                uncertainty: "הסיומת אינה מוכיחה שזה זבל. הקובץ עלול להשתייך ליישום פעיל או להכיל הורדה שתרצו להמשיך; תוכנו לא נקרא.",
                question: "האם ההורדה או העבודה הסתיימו, והאם אתם בטוחים שאין צורך בקובץ הזה לפני העברתו לפח ב־iCloud ובמכשירים המסונכרנים?", isCandidate: true, isCandidateForCloudDeletion: true)
        }
        if old && ["dmg", "pkg", "zip", "tar", "gz", "7z", "rar"].contains(ext) {
            return CloudSuggestion(title: "מתקין או ארכיון ישן לבדיקה", reason: "זהו קובץ מתקין או ארכיון שלא השתנה לפחות 180 יום.",
                uncertainty: "תאריך שינוי אינו תאריך שימוש אחרון. הארכיון עשוי להיות גיבוי יחיד או להכיל מסמכים חשובים; לא נבדקו תוכנו או עותקים נוספים.",
                question: "האם ההתקנה כבר הושלמה או שתוכן הארכיון נשמר במקום אחר, והאם תרצו להעביר דווקא את הקובץ הזה לפח מכל מכשירי iCloud?", isCandidate: true, isCandidateForCloudDeletion: true)
        }
        if old && item.canEvict && item.localBytes > 0 {
            return CloudSuggestion(title: "אפשר לפנות את העותק המקומי", reason: "הקובץ לא השתנה לפחות 180 יום וקיים עותק מקומי שמאושר להסרה לפי מצב הסנכרון בסריקה.",
                uncertainty: "זו הצעה לפינוי מקום במק בלבד; היא אינה מפנה מכסת iCloud. תאריך שינוי אינו מעיד על שימוש אחרון והמצב ייבדק שוב לפני פעולה.",
                question: "האם חשוב לכם שהקובץ יהיה זמין ללא אינטרנט, או שתרצו להסיר רק את העותק מהמק ולהשאיר את המקור ב־iCloud?", isCandidate: true)
        }
        return CloudSuggestion(title: "אין סימן מספיק להמלצת ניקוי", reason: "המטא־נתונים אינם מספקים בסיס להציע שהקובץ מיותר.",
            uncertainty: "גודל, שם וגיל לבדם אינם הוכחה לזבל; תוכן הקובץ, שימוש אחרון ועותקים נוספים לא נבדקו.",
            question: "האם אתם מזהים את הקובץ ויודעים שאינכם צריכים אותו? אם לא, הציגו אותו ב־Finder לפני החלטה.", isCandidate: false)
    }
}
