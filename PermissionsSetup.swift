import SwiftUI
import AppKit
import Foundation

/// A prior directory-listing result, not a grant of access to file contents.
enum PermissionAccessState: String, Codable, CaseIterable {
    case unchecked, granted, denied, missing
    var title: String {
        switch self {
        case .unchecked: return "טרם נבדק"
        case .granted: return "רשימת התיקייה נגישה"
        case .denied: return "אין גישה"
        case .missing: return "התיקייה אינה קיימת"
        }
    }
}
struct PermissionRoot {
    let label: String
    let path: String
    var fullDiskAccessProbe: Bool = false
}
struct PermissionPathStatus: Identifiable, Codable {
    let path: String
    let label: String
    var state: PermissionAccessState
    var checkedAt: Date?
    var fullDiskAccessProbe: Bool = false
    var id: String { path }
}
struct PermissionPlan {
    let excluded: [URL]
    let prepared: Bool
    /// True only means that the chosen protected-directory probe succeeded.
    /// It must never be treated as proof of a universal Full Disk Access grant.
    let fullDiskAccessHint: Bool?
}

enum PermissionPlanner {
    static func make(statuses: [PermissionPathStatus], prepared: Bool) -> PermissionPlan {
        var deniedOrUnknown: [URL] = []
        for status in statuses where status.state != .granted {
            deniedOrUnknown.append(URL(fileURLWithPath: status.path).standardizedFileURL)
        }
        deniedOrUnknown.sort { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
        var excluded: [URL] = []
        for url in deniedOrUnknown {
            if !excluded.contains(where: { url.path == $0.path || $0.path == "/" || url.path.hasPrefix($0.path + "/") }) { excluded.append(url) }
        }
        let probe = statuses.first(where: \.fullDiskAccessProbe)?.state
        let hint: Bool? = probe == .granted ? true : probe == .denied ? false : nil
        return PermissionPlan(excluded: excluded, prepared: prepared, fullDiskAccessHint: hint)
    }
}

/// Permission prompts are initiated only by the user's explicit setup actions.
/// The scanner receives exclusions; unchecked/denied roots must not be probed by it.
@MainActor final class PermissionSetup: ObservableObject {
    static let shared = PermissionSetup()
    @Published var show = false
    @Published private(set) var prepared: Bool
    @Published private(set) var checking = false
    @Published private(set) var statuses: [PermissionPathStatus]
    @Published private(set) var selectedFolders: [URL]
    @Published private(set) var checkedAt: Date?
    @Published private(set) var currentLabel = ""
    @Published var settingsOpened = false
    private let defaults: UserDefaults
    private let roots: [PermissionRoot]
    private let probe: (URL) -> PermissionAccessState
    private let queue = DispatchQueue(label: "storage.permissions.preflight", qos: .userInitiated)
    private let prefix = "StorageStudio.permissions.v1."
    var excludedPaths: [String] { currentPlan.excluded.map(\.path) }
    var currentPlan: PermissionPlan { PermissionPlanner.make(statuses: statuses, prepared: prepared) }

    nonisolated static var defaultRoots: [PermissionRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let ordinary: [(String, String)] = [
            ("שולחן העבודה", "Desktop"), ("מסמכים", "Documents"), ("הורדות", "Downloads"),
            ("תמונות", "Pictures"), ("סרטים", "Movies"), ("מוזיקה", "Music"),
            ("מסמכי iCloud ויישומים", "Library/Mobile Documents"),
            ("iCloud Drive", "Library/Mobile Documents/com~apple~CloudDocs"),
            ("הודעות", "Library/Messages"), ("Safari", "Library/Safari"),
            ("יומנים", "Library/Calendars"), ("אנשי קשר", "Library/Application Support/AddressBook"),
            ("מכולות יישומים", "Library/Containers"), ("מכולות קבוצתיות", "Library/Group Containers"),
            ("חשבונות", "Library/Accounts"), ("HomeKit", "Library/HomeKit"),
            ("זהויות מערכת", "Library/IdentityServices"),
            ("אינדקס Spotlight", "Library/Metadata/CoreSpotlight"),
            ("נתוני התאמה אישית", "Library/PersonalizationPortrait"),
            ("שיתוף", "Library/Sharing"), ("הצעות מערכת", "Library/Suggestions")
        ]
        return ordinary.map { PermissionRoot(label: $0.0, path: home.appendingPathComponent($0.1).path) }
            + [PermissionRoot(label: "דואר — בדיקת תיקייה מוגנת", path: home.appendingPathComponent("Library/Mail").path, fullDiskAccessProbe: true)]
    }

    init(defaults: UserDefaults = .standard, roots: [PermissionRoot]? = nil,
         probe: ((URL) -> PermissionAccessState)? = nil) {
        self.defaults = defaults
        self.roots = roots ?? Self.defaultRoots
        self.probe = probe ?? Self.defaultProbe
        let trustCached = roots != nil || probe != nil || defaults.string(forKey:"StorageStudio.permissions.v1.executable") == Self.executableStamp()
        prepared = trustCached && defaults.bool(forKey: "StorageStudio.permissions.v1.prepared")
        checkedAt = defaults.object(forKey: "StorageStudio.permissions.v1.checkedAt") as? Date
        let restoredFolders = (defaults.stringArray(forKey: "StorageStudio.permissions.v1.selectedFolders") ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        selectedFolders = restoredFolders
        let saved = defaults.data(forKey: "StorageStudio.permissions.v1.statuses")
            .flatMap { try? JSONDecoder().decode([PermissionPathStatus].self, from: $0) } ?? []
        var initial = self.roots.map { root -> PermissionPathStatus in
            let prior = trustCached ? saved.first { $0.path == root.path } : nil
            return PermissionPathStatus(path: root.path, label: root.label, state: prior?.state ?? .unchecked,
                                        checkedAt: prior?.checkedAt, fullDiskAccessProbe: root.fullDiskAccessProbe)
        }
        for folder in restoredFolders where !initial.contains(where: { $0.path == folder.path }) {
            let prior = trustCached ? saved.first { $0.path == folder.path } : nil
            initial.append(PermissionPathStatus(path: folder.path, label: folder.lastPathComponent,
                                                state: prior?.state ?? .unchecked, checkedAt: prior?.checkedAt))
        }
        statuses = initial
    }

    nonisolated private static func executableStamp() -> String {
        guard let url = Bundle.main.executableURL else { return "unknown" }
        let modified = (try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return url.path + ":" + String(modified)
    }

    /// Lists a directory without reading any file contents. ENOENT is distinct
    /// from permission denial; no fileExists shortcut masks access failures.
    nonisolated static func defaultProbe(_ url: URL) -> PermissionAccessState {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            return .granted
        } catch {
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError))
                || (ns.domain == NSPOSIXErrorDomain && ns.code == 2) { return .missing }
            return .denied
        }
    }

    /// Explicit user action: macOS may display one dialog per guarded location.
    func preflight() { runProbes(statuses.map { PermissionRoot(label: $0.label, path: $0.path, fullDiskAccessProbe: $0.fullDiskAccessProbe) }) }

    private func runProbes(_ requested: [PermissionRoot]) {
        guard !checking else { return }
        checking = true; prepared = false; currentLabel = "מכין בדיקת גישה…"
        persist()
        let inspect = probe
        queue.async {
            for root in requested {
                DispatchQueue.main.async { self.currentLabel = root.label }
                let state = inspect(URL(fileURLWithPath: root.path))
                DispatchQueue.main.async {
                    if let index = self.statuses.firstIndex(where: { $0.path == root.path }) {
                        self.statuses[index].state = state
                        self.statuses[index].checkedAt = Date()
                    }
                }
            }
            DispatchQueue.main.async {
                self.checking = false; self.prepared = true; self.checkedAt = Date(); self.currentLabel = ""
                self.defaults.set(Self.executableStamp(),forKey:self.prefix + "executable")
                self.persist()
            }
        }
    }

    /// Opens the pane only; it never grants or changes an OS permission.
    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        settingsOpened = NSWorkspace.shared.open(url)
        if !settingsOpened {
            settingsOpened = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    /// Alternative: the user explicitly chooses folders in macOS's own picker.
    /// Approving a child never marks its protected parent as granted. A scanner
    /// using selectedFolders must honor that exact-root exception only, not siblings.
    func chooseFolders() {
        guard !checking else { return }
        let panel = NSOpenPanel()
        panel.title = "בחר תיקיות לסריקה"
        panel.message = "בחר רק תיקיות שברצונך לאפשר לאפליקציה לסרוק."
        panel.prompt = "בחר ובדוק גישה"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls.map(\.standardizedFileURL) {
            if !selectedFolders.contains(where: { $0.path == url.path }) { selectedFolders.append(url) }
            if !statuses.contains(where: { $0.path == url.path }) {
                statuses.append(PermissionPathStatus(path: url.path, label: url.lastPathComponent, state: .unchecked))
            }
        }
        persist()
        runProbes(panel.urls.map { PermissionRoot(label: $0.lastPathComponent, path: $0.standardizedFileURL.path) })
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(statuses) { defaults.set(data, forKey: prefix + "statuses") }
        defaults.set(prepared, forKey: prefix + "prepared")
        defaults.set(selectedFolders.map(\.path), forKey: prefix + "selectedFolders")
        if let checkedAt { defaults.set(checkedAt, forKey: prefix + "checkedAt") }
    }
}

@MainActor struct PermissionSetupView: View {
    @ObservedObject private var setup: PermissionSetup
    let onDone: () -> Void
    init(setup: PermissionSetup? = nil, onDone: @escaping () -> Void) {
        self.setup = setup ?? .shared; self.onDone = onDone
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("מאפשרים לאפליקציה לראות את הקבצים", systemImage: "hand.raised.shield.fill")
                .font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
            Text("לחצו על ״בדיקת גישה״ ואשרו ב־macOS את התיקיות שתרצו לסרוק. תיקיות שלא נבדקו או לא אושרו לא ייסרקו.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(setup.prepared ? "בדיקת גישה מחדש" : "בדיקת גישה", action: setup.preflight)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(setup.checking)
                Button("בחר תיקיות בעצמך…", action: setup.chooseFolders).buttonStyle(StudioButtonStyle()).disabled(setup.checking)

            }
            if setup.checking { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(setup.currentLabel).font(.caption).lineLimit(1) } }
            Button("פתח הגדרות גישה מלאה לכונן", action: setup.openSettings).buttonStyle(StudioButtonStyle())
            ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label("1 · בודקים גישה", systemImage: "folder.badge.questionmark")
                Image(systemName: "chevron.left").font(.caption2)
                Label("2 · בוחרים מה לסרוק", systemImage: "checkmark.shield")
            }.font(.caption.weight(.medium)).foregroundStyle(Palette.accent)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text("גישה מלאה לכונן — הגדרה ידנית").font(.headline)
                Text("אין דרך לבקש או להעניק גישה מלאה לכונן באמצעות כפתור הרשאה רגיל. בהגדרות מערכת › פרטיות ואבטחה › גישה מלאה לכונן, הוסף את האפליקציה הבנויה במיקומה הקבוע. ייתכן שתידרש פתיחה מחדש. לאחר מכן חזור ובדוק גישה מחדש.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("הכפתור פותח הגדרות בלבד; ההחלטה והשינוי הם שלך. הצלחת בדיקת תיקייה בודדת אינה הוכחה לגישה מלאה לכל המחשב.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(14).studioPanel(radius: 14)
            LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(setup.statuses) { status in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(status.state)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(status.state)).frame(width: 30, height: 30).background(color(status.state).opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(status.label).font(.caption.bold()); Spacer(); Text(status.state.title).font(.caption).foregroundStyle(color(status.state)) }
                                Text(status.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).environment(\.layoutDirection, .leftToRight)
                            }
                        }.padding(12).studioPanel(radius: 14).studioHover(radius: 14)
                    }
            }
            Text("ההרשאות נשמרות כממצאי בדיקה מקומיים. Apple יכולה לשנות או לבטל הרשאות, ונתיבים מוגנים חדשים עדיין עלולים להציג בקשה; לא ניתן להבטיח אפס חלונות מערכת.")
                .font(.caption2).foregroundStyle(.secondary)
            } }
            ResponsiveRow {
                Text("\(setup.excludedPaths.count) נתיבים לא אושרו או טרם נבדקו").font(.caption).foregroundStyle(.secondary)
                Button("המשך עם ההרשאות הנוכחיות") { setup.show = false; onDone() }
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(setup.checking || !setup.prepared)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).studioPanel(radius: 14, accented: true)
        }.padding(22).responsiveSheet(width: 720,height: 700).background(AmbientBackground()).tint(Palette.accent).environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
            .interactiveDismissDisabled(setup.checking)
    }
    private func icon(_ state: PermissionAccessState) -> String {
        switch state { case .granted: return "checkmark.circle.fill"; case .denied: return "lock.fill"; case .missing: return "minus.circle"; case .unchecked: return "questionmark.circle" }
    }
    private func color(_ state: PermissionAccessState) -> Color {
        switch state { case .granted: return .green; case .denied: return .orange; case .missing: return .secondary; case .unchecked: return .secondary }
    }
}
