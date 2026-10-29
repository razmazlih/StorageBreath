import SwiftUI
import AppKit

#if !TESTING
@main
struct StorageApp: App {
    @StateObject private var model = ExplorerModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("מפנה אחסון",id:"storage-main") { DashboardView(model:model).frame(minWidth: 620, minHeight: 520).environment(\.layoutDirection, .rightToLeft) }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 880)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("מקום לנשום",systemImage:"externaldrive") {
            Text(model.scanning ? (model.paused ? "הסריקה מושהית" : "סריקה פועלת ברקע") : "\(model.inventoryCount.formatted()) קבצים באינדקס")
            Button("פתח את האפליקציה") { openWindow(id:"storage-main"); NSApplication.shared.activate(ignoringOtherApps:true) }
            if model.scanning {
                Button(model.paused ? "המשך סריקה" : "השהה סריקה") { model.togglePause() }
                Button("עצור ושמור נקודת המשך") { model.engine.cancel() }
            }
            Divider()
            Button("יציאה") { model.engine.cancel(); NSApplication.shared.terminate(nil) }
        }

    }
}

#endif

@MainActor final class StorageModel: ObservableObject {
    @Published var items: [ScanItem] = []
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var scanning = false
    @Published var scanProgress = ScanProgress(stage: "מכין סריקה", currentPath: "", inspected: 0, found: 0, bytes: 0)
    @Published var startedAt = Date()
    @Published var status = "מוכן לסריקה מקומית ופרטית"
    @Published var scanned = false
    @Published var skipped = 0
    @Published var search = ""
    @Published var sort: FileSort = .largest
    @Published var category = "הכול"
    @Published var message = ""
    @Published var showMessage = false
    @Published var confirm = false
    @Published var cloudMode = false
    let engine = StorageEngine()
    var total: Int64 { items.filter { !ProtectionStore.shared.isProtected($0.path) }.reduce(0) { $0 + $1.bytes } }
    var chosen: [ScanItem] { items.filter { selected.contains($0.id) && !ProtectionStore.shared.isProtected($0.path) } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var visible: [ScanItem] { items.filter { !ProtectionStore.shared.isProtected($0.path) && (category == "הכול" || $0.category == category) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)) }.sorted { sort.before(($0.title, $0.path, $0.bytes), ($1.title, $1.path, $1.bytes)) } }
    var categories: [String] { ["הכול"] + Array(Set(items.map(\.category))).sorted() }
    func scan() {
        busy = true; scanning = true; selected = []; items = []; scanned = false; startedAt = Date(); scanProgress = ScanProgress(stage: "מכין סריקה", currentPath: "", inspected: 0, found: 0, bytes: 0); status = "סורק תיקיות מקומיות…"
        let worker = engine
        DispatchQueue.global(qos: .userInitiated).async {
            let report = worker.scan(progress: { path in
                DispatchQueue.main.async { self.status = path }
            }, details: { update in DispatchQueue.main.async { self.scanProgress = update } })
            DispatchQueue.main.async {
                self.items = report.items; self.skipped = report.skipped
                self.scanned = true; self.busy = false; self.scanning = false
                self.status = "\(report.limited ? "הסריקה הסתיימה עם כיסוי חלקי — הגעה למגבלה" : "הסריקה הושלמה") · \(report.inspected) פריטים נבדקו"
            }
        }
    }
    func trash() {
        let targets = chosen
        busy = true; status = "מעביר לפח…"
        let worker = engine
        DispatchQueue.global(qos: .userInitiated).async {
        worker.trash(targets) { errors in
            DispatchQueue.main.async {
                self.busy = false
                self.message = errors.isEmpty ? "הפריטים הועברו לפח. ניתן לשחזר אותם דרך Finder. המקום יתפנה לאחר ריקון הפח באופן ידני." : "חלק מהפעולות לא הושלמו:\n" + errors.joined(separator: "\n")
                self.showMessage = true
                self.scan()
            }
        }
        }
    }
}
func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion = MotionState()
    @ObservedObject private var protection = ProtectionUI.shared
    @ObservedObject var model: StorageModel
    var disk: (Int64, Int64) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack { Image(systemName: "sparkles.rectangle.stack.fill").font(.title).foregroundStyle(Palette.accent); Text("מקום לנשום").font(.title2.bold()) }.padding(.top, 35)
                Text("ניהול אחסון חכם למק שלך").font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Label("מבט על האחסון", systemImage: "internaldrive").font(.headline)
                    Text("\(size(disk.1)) זמינים מתוך \(size(disk.0))").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(max(0,disk.0-disk.1)), total: Double(max(1,disk.0))).tint(Palette.accent)
                }.padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Button { model.cloudMode = false } label: { Label("אחסון במק", systemImage: "internaldrive").padding(10) }.buttonStyle(MotionButtonStyle(prominent: false))
                    Button { model.cloudMode = true } label: { Label("iCloud Drive", systemImage: "icloud").padding(10) }.buttonStyle(MotionButtonStyle(prominent: false))
                    Button { protection.manager = true } label: { Label("קבצים מוגנים", systemImage: "lock.shield").padding(10) }.buttonStyle(MotionButtonStyle(prominent: false))
                    Divider().padding(.vertical, 6)
                    Text("קטגוריות").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.categories, id: \.self) { category in
                        Button { model.category = category } label: {
                            HStack { Image(systemName: category == "הכול" ? "square.grid.2x2" : "folder"); Text(category); Spacer() }.padding(11).background(model.category == category ? Palette.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(MotionButtonStyle(prominent: false))
                    }
                }
                Spacer()
                Label("סריקה מקומית · ללא שרת חיצוני", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Text("כל פעולת ניקוי דורשת אישור").font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(width: 270).background(Color(red: 0.05, green: 0.058, blue: 0.078))
            if model.cloudMode { CloudView() } else {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) { Text("מפנים מקום. משאירים שליטה.").font(.system(size: 31, weight: .bold, design: .rounded)); Text("גלו קבצים גדולים ומטמונים שאפשר לבדוק לפני ניקוי.").foregroundStyle(.secondary) }
                    Spacer()
                    Button(action: model.scan) { Label(model.scanned ? "סריקה מחדש" : "סריקת האחסון", systemImage: "arrow.clockwise").padding(7) }.buttonStyle(MotionButtonStyle()).disabled(model.busy)
                }
                HStack(spacing: 14) {
                    metric("מועמדים לבדיקה", value: size(model.total), symbol: "externaldrive.badge.magnifyingglass")
                    metric("פריטים שנמצאו", value: "\(model.items.count)", symbol: "doc.on.doc")
                    metric("נבחרו להעברה לפח", value: size(model.chosenBytes), symbol: "trash")
                }
                HStack { if model.busy { ScanPulseView().scaleEffect(0.21).frame(width: 28, height: 28) }; Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer() }
                if model.scanning { ScanActivityPanel(progress: model.scanProgress, startedAt: model.startedAt) }
                if model.skipped > 0 { Text("\(model.skipped) פריטים לא נסרקו או דולגו. הסריקה אינה כוללת את כל שטח הדיסק.").font(.caption).foregroundStyle(.orange) }
                HStack { Text("ממצאי הסריקה").font(.title3.bold()); Spacer(); FileTools(search: $model.search, sort: $model.sort).frame(maxWidth: 470) }
                if model.scanned {
                    HStack {
                        Button { model.selected = Set(model.items.filter { $0.category == "קבצים זמניים ישנים" && !ProtectionStore.shared.isProtected($0.path) }.map(\.id)) } label: { Label("בחר זמניים ישנים", systemImage: "sparkles") }.buttonStyle(MotionButtonStyle(prominent: false)).disabled(model.busy)
                        Text("זמניים בני 7 ימים לפחות · ללא פריטים מוגנים").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.visible.count) מוצגים").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.scanned && !model.busy {
                    Spacer(); VStack(spacing: 16) { ScanPulseView().frame(width: 120, height: 120); Text("עוד קצת מקום לדברים החשובים").font(.title2.bold()); Text("הסריקה בודקת מטמונים, יומנים, הורדות וקבצים גדולים.\nמסמכים אישיים דורשים בדיקה שלך לפני העברה לפח.").multilineTextAlignment(.center).foregroundStyle(.secondary) }.frame(maxWidth: .infinity); Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(model.visible) { item in
                                HStack(spacing: 14) {
                                    Toggle("בחר \(item.title)", isOn: Binding(get: { model.selected.contains(item.id) }, set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })).labelsHidden().toggleStyle(AnimatedCheckStyle(title: "בחר \(item.title)")).disabled(model.busy || ProtectionStore.shared.isProtected(item.path))
                                    Image(systemName: item.risk == .safe ? "archivebox" : "doc.text.magnifyingglass").font(.title2).foregroundStyle(item.risk == .safe ? Palette.accent : .orange).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.headline).lineLimit(1); Text(item.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).environment(\.layoutDirection, .leftToRight); Text(item.risk == .safe ? "תוצר בנייה · ניתן ליצור מחדש" : "דורש בדיקה אישית").font(.caption2).foregroundStyle(item.risk == .safe ? Palette.accent : .orange) }
                                    ProtectionControl(path: item.path) { model.selected.remove(item.id) }
                                    Spacer(); Text(size(item.bytes)).font(.headline).monospacedDigit()
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder") }.help("הצג ב־Finder").buttonStyle(.borderless)
                                }.padding(15).background(.white.opacity(motion.hovered == item.id ? 0.085 : 0.035), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(motion.hovered == item.id ? 0.30 : 0.05), lineWidth: 1)).scaleEffect(motion.hovered == item.id && !reduceMotion ? 1.008 : 1).onHover { motion.hovered = $0 ? item.id : nil }.animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: motion.hovered).transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            if model.scanned && !model.busy && model.visible.isEmpty { Text("לא נמצאו פריטים להצגה").foregroundStyle(.secondary).padding(35) }
                        }
                    }
                }
                HStack {
                    Text("העברה לפח אינה מפנה מקום עד לריקונו.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("העבר לפח (\(model.selected.count))") { model.confirm = true }.buttonStyle(MotionButtonStyle(prominent: false)).tint(.red).disabled(model.chosen.isEmpty || model.busy)
                }
            }.padding(30).background(AmbientBackground())
            }
        }.preferredColorScheme(.dark)
        .sheet(isPresented: $protection.manager) { ProtectionManager() }
        .sheet(isPresented: Binding(get: { protection.customPath != nil }, set: { if !$0 { protection.customPath = nil } })) { ProtectionDateSheet() }
        .onChange(of: protection.revision) { _ in model.selected = model.selected.filter { !ProtectionStore.shared.isProtected($0) } }
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88), value: model.scanned)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.category)
        .alert("להעביר \(model.selected.count) פריטים לפח?", isPresented: $model.confirm) { Button("ביטול", role: .cancel) {}; Button("העבר לפח", role: .destructive) { model.trash() } } message: { Text("נבחרו \(size(model.chosenBytes)). סגור אפליקציות שמשתמשות בקבצים האלה. ניתן לשחזר דרך הפח ב־Finder; האפליקציה לא מרוקנת אותו.") }
        .alert("תוצאת הניקוי", isPresented: $model.showMessage) { Button("אישור", role: .cancel) {} } message: { Text(model.message) }
    }
    func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).foregroundStyle(Palette.accent) }; Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).environment(\.layoutDirection, .leftToRight) }.padding(18).frame(maxWidth: .infinity).background(LinearGradient(colors: [.white.opacity(0.095), .white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.10), lineWidth: 1)).shadow(color: .black.opacity(0.12), radius: 15, y: 8)
    }
}

@MainActor final class MotionState: ObservableObject { @Published var hovered: String? }
