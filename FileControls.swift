import SwiftUI
import Combine

enum FileSort: String, CaseIterable, Identifiable {
    case largest = "גודל: גדול לקטן", smallest = "גודל: קטן לגדול", name = "שם: א–ת", kind = "סוג קובץ"
    var id: String { rawValue }
    func before(_ a: (String, String, Int64), _ b: (String, String, Int64)) -> Bool {
        if self == .largest && a.2 != b.2 { return a.2 > b.2 }
        if self == .smallest && a.2 != b.2 { return a.2 < b.2 }
        if self == .largest || self == .smallest { return a.1 < b.1 }
        if self == .kind {
            let ae = (a.1 as NSString).pathExtension.lowercased(), be = (b.1 as NSString).pathExtension.lowercased()
            if ae != be { return ae < be }
        }
        let order = a.0.localizedStandardCompare(b.0)
        return order == .orderedSame ? a.1 < b.1 : order == .orderedAscending
    }
}
@MainActor final class ProtectionUI: ObservableObject {
    static let shared = ProtectionUI()
    @Published var revision = 0
    @Published var manager = false
    @Published var customPath: String?
    @Published var date = Date().addingTimeInterval(86400)
    var timer: AnyCancellable?
    private var lastStoreRevision: UInt64?
    init() { timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
        guard let self else { return }
        let current = ProtectionStore.shared.revision()
        if current != self.lastStoreRevision { self.lastStoreRevision = current; self.revision += 1 }
    } }
    func protect(_ path: String, days: Int? = nil) {
        ProtectionStore.shared.protect(path, until: days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: Date()) })
        revision += 1
    }
    func remove(_ path: String) { ProtectionStore.shared.unprotect(path); revision += 1 }
}
struct FileTools: View {
    @Binding var search: String
    @Binding var sort: FileSort
    @State private var showSort = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(searchFocused ? Palette.accent : .secondary)
                TextField("חיפוש לפי שם או נתיב", text: $search).textFieldStyle(.plain).focused($searchFocused).frame(minWidth: 100, maxWidth: .infinity)
            }.padding(.horizontal, 12).padding(.vertical, 9).studioPanel(radius: 12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(searchFocused ? 0.65 : 0), lineWidth: 1))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: searchFocused)
            Button { showSort = true } label: { Label("מיון", systemImage: "arrow.up.arrow.down") }.buttonStyle(StudioButtonStyle()).help(sort.rawValue)
        }.sheet(isPresented: $showSort) {
            VStack(alignment: .leading, spacing: 18) {
                Label("מיון קבצים", systemImage: "arrow.up.arrow.down.circle.fill").font(.title2.bold()).foregroundStyle(Palette.accent)
                VisibleChoices(title: "סדר התוצאות", selection: $sort, options: FileSort.allCases.map { ($0.rawValue, $0) })
                Button("סגור") { showSort = false }.buttonStyle(StudioButtonStyle(prominent: true))
            }.padding(24).responsiveSheet(width: 480).environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
        }
    }
}
struct ProtectionControl: View {
    let path: String
    var didChange: () -> Void
    @ObservedObject private var ui = ProtectionUI.shared
    @State private var showActions = false
    @State private var requestDate = false
    var body: some View {
        let label = ProtectionStore.shared.ruleLabel(path)
        Button { showActions = true } label: {
            Label(label == nil ? "הגנה" : (label == "מוגן תמיד" ? "מוגן תמיד" : "מוגן זמנית"), systemImage: label == nil ? "shield" : "lock.shield.fill").font(.caption).foregroundStyle(label == nil ? Color.secondary : Palette.accent).lineLimit(1)
        }.buttonStyle(StudioButtonStyle()).fixedSize().help(label ?? "לא למחוק קובץ זה")
        .sheet(isPresented: $showActions, onDismiss: {
            if requestDate { requestDate = false; ui.date = Date().addingTimeInterval(86400); ui.customPath = path }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Label("הגנה מניקוי", systemImage: "lock.shield").font(.title2.bold())
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).studioPanel(radius: 12)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                    Button("ללא הגבלת זמן") { ui.protect(path); didChange(); showActions = false }
                    Button("ליום") { ui.protect(path, days: 1); didChange(); showActions = false }
                    Button("לשבוע") { ui.protect(path, days: 7); didChange(); showActions = false }
                    Button("לחודש") { ui.protect(path, days: 30); didChange(); showActions = false }
                    Button("עד תאריך ושעה…") { requestDate = true; didChange(); showActions = false }
                    if label != nil { Button("הסר הגנה") { ui.remove(path); didChange(); showActions = false } }
                }.buttonStyle(StudioButtonStyle())
                Button("סגור") { showActions = false }.buttonStyle(StudioButtonStyle(prominent: true))
            }.padding(24).responsiveSheet(width: 500).environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
        }
    }
}
struct ProtectionDateSheet: View {
    @ObservedObject private var ui = ProtectionUI.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("לא למחוק עד…", systemImage: "lock.shield.fill").font(.title2.bold()).foregroundStyle(Palette.accent)
            ScrollView { VStack(alignment: .leading, spacing: 16) {
            Text(ui.customPath ?? "").font(.caption).lineLimit(2)
            DatePicker("תום ההגנה", selection: $ui.date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            Text("ההגנה חלה על פעולות ניקוי באפליקציה, כולל הסרת עותק מקומי מ־iCloud. פקיעתה אינה מפעילה מחיקה אוטומטית.").font(.caption).foregroundStyle(.secondary)
            } }
            HStack { Button("ביטול") { ui.customPath = nil }.buttonStyle(StudioButtonStyle()); Spacer(); Button("שמור הגנה") { if let path = ui.customPath { ProtectionStore.shared.protect(path, until: ui.date); ui.revision += 1 }; ui.customPath = nil }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(ui.date <= Date()) }
        }.padding(24).responsiveSheet(width: 490,height: 360).environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
    }
}

struct ProtectionManager: View {
    @ObservedObject private var ui = ProtectionUI.shared
    @State private var search = ""
    @State private var filter = "הכול"
    @State private var sort = "שם"
    @State private var page = 0
    private let pageSize = 50

    var body: some View {
        let entries = ProtectionStore.shared.entries()
        let tokens = search.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matches = entries.filter { entry in
            (filter == "הכול" || (filter == "קבועות" ? entry.until == nil : entry.until != nil)) &&
            tokens.allSatisfy { entry.path.localizedCaseInsensitiveContains($0) }
        }.sorted { a, b in
            if sort == "תום ההגנה", a.until != b.until { return (a.until ?? .distantFuture) < (b.until ?? .distantFuture) }
            if sort == "נתיב" { return a.path.localizedStandardCompare(b.path) == .orderedAscending }
            let nameA = URL(fileURLWithPath: a.path).lastPathComponent
            let nameB = URL(fileURLWithPath: b.path).lastPathComponent
            let order = nameA.localizedStandardCompare(nameB)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
        let lastPage = max(0, (matches.count - 1) / pageSize)
        let currentPage = min(page, lastPage)
        let start = currentPage * pageSize
        let visible = Array(matches.dropFirst(start).prefix(pageSize))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("קבצים מוגנים", systemImage: "lock.shield.fill").font(.title2.bold()).foregroundStyle(Palette.accent)
                Spacer()
                Text("\(entries.count.formatted()) הגנות פעילות").font(.subheadline).monospacedDigit()
            }
            Text("כל שורה היא הגנה על נתיב אחד. הגנה על תיקייה חלה גם על התוכן שלה; הגנה על קובץ חוסמת ניקוי של תיקיות שמכילות אותו.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                TextField("חיפוש בשם הקובץ או בנתיב…", text: $search).textFieldStyle(.roundedBorder)
                HStack { if !search.isEmpty { Button("נקה חיפוש") { search = "" }.buttonStyle(StudioButtonStyle()) }
                Spacer()
                }
                VisibleChoices(title: "מיון", selection: $sort, options: [("שם", "שם"), ("נתיב", "נתיב"), ("תום ההגנה", "תום ההגנה")])
            }
            VisibleChoices(title: "סוג הגנה", selection: $filter, options: [("הכול (\(entries.count))", "הכול"), ("קבועות (\(entries.filter { $0.until == nil }.count))", "קבועות"), ("זמניות (\(entries.filter { $0.until != nil }.count))", "זמניות")])
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("top")
                        ForEach(visible) { entry in
                            protectionRow(entry)
                        }
                        if matches.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: entries.isEmpty ? "shield" : "magnifyingglass").font(.largeTitle)
                                Text(entries.isEmpty ? "אין כרגע הגנות פעילות" : "לא נמצאו הגנות התואמות לחיפוש ולסינון").font(.headline)
                                if !entries.isEmpty { Button("הצג את כל ההגנות") { search = ""; filter = "הכול" } }
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                        }
                    }
                }
                .onChange(of: currentPage) { _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: search) { _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: filter) { _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: sort) { _ in proxy.scrollTo("top", anchor: .top) }
            }
            ResponsiveRow {
                Text(matches.isEmpty ? "0 תוצאות" : "\((start + 1).formatted())–\((start + visible.count).formatted()) מתוך \(matches.count.formatted())").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) { Button("הקודם") { page = currentPage - 1 }.disabled(currentPage == 0)
                Text("עמוד \(currentPage + 1) מתוך \(lastPage + 1)").font(.caption).monospacedDigit()
                Button("הבא") { page = currentPage + 1 }.disabled(currentPage == lastPage) }
            }
            Divider()
            ResponsiveRow {
                Text("ההגנות חלות באפליקציה בלבד ונשמרות לפי נתיב. שינוי שם או מיקום מחייב הגדרה מחדש. פקיעת הגנה אינה מפעילה ניקוי.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("סגור") { ui.manager = false }.buttonStyle(StudioButtonStyle(prominent: true)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).responsiveSheet(width: 820, height: 620).background(AmbientBackground())
        .environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark)
        .onChange(of: search) { _ in page = 0 }
        .onChange(of: filter) { _ in page = 0 }
        .onChange(of: sort) { _ in page = 0 }
        .onChange(of: ui.revision) { _ in page = min(page, lastPage) }
    }

    private func protectionRow(_ entry: ProtectionEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(Palette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.path == "/" ? "/" : URL(fileURLWithPath: entry.path).lastPathComponent)
                    .font(.headline).lineLimit(1).truncationMode(.middle).help(entry.path)
                Text(entry.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled).help(entry.path)
                Label(entry.until.map { "עד " + $0.formatted(date: .numeric, time: .shortened) } ?? "ללא הגבלת זמן",
                      systemImage: entry.until == nil ? "infinity" : "clock")
                    .font(.caption).foregroundStyle(Palette.accent)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "") } label: {
                Image(systemName: "folder").frame(width: 24, height: 24)
            }.buttonStyle(StudioButtonStyle()).help("הצג ב־Finder").accessibilityLabel("הצג ב־Finder")
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }.buttonStyle(StudioButtonStyle()).help("העתק נתיב מלא").accessibilityLabel("העתק נתיב מלא")
            Button("הסר הגנה") { ui.remove(entry.path) }.buttonStyle(StudioButtonStyle()).font(.caption)
        }.padding(12).studioPanel(radius: 14).studioHover(radius: 14)
    }
}

struct ScanActivityPanel: View {
    let progress: ScanProgress
    let startedAt: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ScanPulseView().scaleEffect(0.28).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("הסריקה פועלת עכשיו").font(.headline).foregroundStyle(Palette.accent)
                    Text("בודק: " + progress.stage).font(.subheadline)
                }
                Spacer()
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt)))) שניות").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let fraction = progress.directoryFraction, let percent = progress.directoryPercent, let done = progress.completedDirectories, let discovered = progress.discoveredDirectories {
                ResponsiveRow {
                    Text("אומדן התקדמות: \(percent)%").font(.headline).monospacedDigit()
                    Spacer()
                    Text("\(done.formatted()) מתוך \(discovered.formatted()) תיקיות שהתגלו").font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value:fraction,total:1).tint(Palette.accent)
                Text("האומדן מתייחס לתיקיות שהתגלו בהיקף שבחרת, ועשוי להשתנות עם גילוי תיקיות נוספות. דילוגים מפורטים בדוח הכיסוי.").font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Palette.accent)
                Text("מגלה תיקיות לחישוב אומדן…").font(.caption2).foregroundStyle(.secondary)
            }
            ResponsiveRow {
                Text("\(progress.inspected.formatted()) פריטים נבדקו")
                Spacer()
                Text("\(progress.found) ממצאים · \(size(progress.bytes))")
            }.font(.caption).foregroundStyle(.secondary)
            if !progress.currentPath.isEmpty { Text(progress.currentPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).environment(\.layoutDirection, .leftToRight) }
            Text("הסריקה קוראת נתוני קבצים בלבד. אין מחיקה בזמן הסריקה.").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.18), lineWidth: 1))
    }
}
