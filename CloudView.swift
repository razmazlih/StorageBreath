import SwiftUI
import AppKit

/// Cooperative cancellation covers both filtering and sorting large cloud inventories.
private final class CloudWorkEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ expected: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == expected }
    static func sorted<T>(_ input: [T], current: () -> Bool, before: (T,T) -> Bool) -> [T]? {
        guard current() else { return nil }
        guard input.count > 1 else { return input }
        var source = input, target = input, width = 1
        while width < source.count {
            for lower in stride(from: 0, to: source.count, by: width * 2) {
                guard current() else { return nil }
                let middle = min(lower + width, source.count), upper = min(lower + width * 2, source.count)
                var left = lower, right = middle
                for index in lower..<upper {
                    if index % 256 == 0 && !current() { return nil }
                    if left < middle && (right >= upper || !before(source[right],source[left])) {
                        target[index] = source[left]; left += 1
                    } else { target[index] = source[right]; right += 1 }
                }
            }
            swap(&source, &target); width *= 2
        }
        return current() ? source : nil
    }
}

@MainActor final class CloudModel: ObservableObject {
    static let shared = CloudModel()
    @Published var items: [CloudItem] = [] { didSet { cancelAI(); refreshSelection(); rebuild() } }
    @Published var ai = false
    @Published private(set) var preparingAI = false
    @Published private(set) var aiCandidates: [AICandidate] = []
    @Published private(set) var aiSource: AISource = .cloudEvict
    private let aiEpoch = CloudWorkEpoch()
    @Published var suggestionsOnly = false { didSet { scheduleFilter() } }
    @Published var detail: CloudItem?
    @Published var showIssues = false
    @Published var issues: [CloudScanIssue] = []
    @Published var visible: [CloudItem] = []
    @Published var page = 0
    @Published var search = "" { didSet { scheduleFilter() } }
    @Published var sort: FileSort = .largest { didSet { scheduleFilter() } }
    @Published var selected: Set<String> = [] { didSet { refreshSelection() } }
    @Published var busy = false
    @Published var scanning = false
    @Published var scanProgress = ScanProgress(stage: "מכין סריקה", currentPath: "", inspected: 0, found: 0, bytes: 0)
    @Published var startedAt = Date()
    @Published private(set) var cleanupSucceeded = false
    @Published var scanned = false
    @Published var evict = true { didSet { cancelAI(); refreshSelection() } }
    @Published var confirm = false
    @Published var alert = false
    @Published var message = ""
    @Published var status = "סריקה של מסמכי iCloud ותיקיות יישומים"
    let engine = CloudEngine()
    @Published private(set) var chosen: [CloudItem] = []
    @Published private(set) var amount: Int64 = 0
    @Published private(set) var selectionUpdating = false
    private let selectionEpoch = CloudWorkEpoch()
    private let filterEpoch = CloudWorkEpoch()
    private var filterWork: DispatchWorkItem?
    private let selectionQueue = DispatchQueue(label: "storage.cloud.selection", qos: .userInitiated)
    private let filterQueue = DispatchQueue(label: "storage.cloud.filter",qos:.userInitiated)
    func refreshSelection() {
        let generation = selectionEpoch.advance(), epoch = selectionEpoch
        guard !selected.isEmpty else { chosen = []; amount = 0; selectionUpdating = false; return }
        selectionUpdating = true
        let inventory = items, ids = selected, local = evict, protected = AIFlowModel.protectionCheck()
        selectionQueue.async {
            guard epoch.current(generation) else { return }
            var output: [CloudItem] = [], bytes: Int64 = 0
            for (index, item) in inventory.enumerated() {
                if index % 256 == 0 && !epoch.current(generation) { return }
                if ids.contains(item.id) && (local ? item.canEvict : item.canDelete) && !protected(item.path) {
                    output.append(item); bytes += local ? item.localBytes : item.logicalBytes
                }
            }
            let result = output, total = bytes
            DispatchQueue.main.async {
                guard epoch.current(generation) else { return }
                self.chosen = result; self.amount = total; self.selectionUpdating = false
            }
        }
    }
    func protectionsChanged() { cancelAI(); refreshSelection(); rebuild() }
    var pageCount: Int { max(1,(visible.count+99)/100) }
    var pageItems: [CloudItem] { let lower = min(page*100,visible.count); return Array(visible[lower..<min(lower+100,visible.count)]) }
    func scheduleFilter() { _ = filterEpoch.advance(); filterWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.rebuild() }; filterWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work) }
    func rebuild() {
        let generation = filterEpoch.advance(), epoch = filterEpoch
        let onlySuggestions = suggestionsOnly
        let inventory = items, tokens = search.split(whereSeparator: { $0.isWhitespace }).map(String.init), sorting = sort, local = evict, protected = AIFlowModel.protectionCheck()
        filterQueue.async {
            guard epoch.current(generation) else { return }
            var matches: [CloudItem] = []
            for (index, item) in inventory.enumerated() {
                if index % 256 == 0 && !epoch.current(generation) { return }
                if (!onlySuggestions || (local ? CloudSuggestion.evaluate(item).isCandidate : CloudSuggestion.evaluate(item).isCandidateForCloudDeletion)) && !protected(item.path) && tokens.allSatisfy({ token in item.title.localizedCaseInsensitiveContains(token) || item.path.localizedCaseInsensitiveContains(token) }) { matches.append(item) }
            }
            guard let output = CloudWorkEpoch.sorted(matches, current: { epoch.current(generation) }, before: { sorting.before(($0.title,$0.path,local ? $0.localBytes : $0.logicalBytes),($1.title,$1.path,local ? $1.localBytes : $1.logicalBytes)) }) else { return }
            DispatchQueue.main.async { guard epoch.current(generation) else { return }; self.visible = output; self.page = 0 }
        }
    }

    func cancelAI() { _ = aiEpoch.advance(); preparingAI = false }
    func openAI() {
        guard !busy, !preparingAI else { return }
        let generation = aiEpoch.advance(), epoch = aiEpoch
        let inventory = items, local = evict, protected = AIFlowModel.protectionCheck()
        preparingAI = true
        DispatchQueue.global(qos: .userInitiated).async {
            var candidates: [AICandidate] = []
            for (index, item) in inventory.enumerated() {
                if index % 256 == 0 && !epoch.current(generation) { return }
                guard (local ? item.canEvict : item.canDelete), !protected(item.path) else { continue }
                candidates.append(AICandidate(id:item.id,path:item.path,title:item.title,category:"iCloud Drive",bytes:local ? item.localBytes : item.logicalBytes,modified:item.modified,temporary:false,allowed:true,reason:"קובץ iCloud; המלצה מחייבת בדיקה אישית"))
            }
            let result = candidates
            DispatchQueue.main.async {
                guard epoch.current(generation) else { return }
                self.aiCandidates = result; self.aiSource = local ? .cloudEvict : .cloudDelete
                self.preparingAI = false; self.ai = true
            }
        }
    }
    func scan() {
        guard !busy else { return }
        cancelAI()
        guard PermissionSetup.shared.prepared else { PermissionSetup.shared.show = true; return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents").path
        guard !PermissionSetup.shared.excludedPaths.contains(where:{ root == $0 || root.hasPrefix($0+"/") }) else { message = "גישה ל־iCloud לא אושרה בהכנת ההרשאות. פתח הכנת הרשאות ובדוק גישה לפני הסריקה."; alert = true; return }

        cleanupSucceeded = false
        busy = true; scanning = true; selected = []; items = []; visible = []; issues = []; page = 0; scanned = false; startedAt = Date(); status = "בודק קובצי iCloud בלי להוריד את התוכן…"
        let worker = engine
        let exclusions = PermissionSetup.shared.excludedPaths
        DispatchQueue.global(qos: .background).async {
            let report = worker.scan(excludingPaths: exclusions, progress: { update in DispatchQueue.main.async { self.scanProgress = update } })
            DispatchQueue.main.async {
                self.items = report.items; self.issues = report.issues; self.rebuild(); self.busy = false; self.scanning = false; self.scanned = true
                self.status = "\(report.cancelled ? "הסריקה נעצרה — תוצאות חלקיות" : "הסריקה העמוקה הושלמה") · \(report.items.count) קבצים · \(report.skipped) פריטים דולגו / לא נגישים · סריקה ללא מגבלת זמן או כמות"
            }
        }
    }
    func act() {
        guard !selectionUpdating, !preparingAI, !busy, !chosen.isEmpty else { return }
        let targets = chosen
        let localOnly = evict
        cleanupSucceeded = false
        busy = true
        let worker = engine
        DispatchQueue.global(qos: .userInitiated).async {
        worker.act(items: targets, evict: localOnly) { errors in
            DispatchQueue.main.async {
                self.message = errors.isEmpty ? (localOnly ? "בקשת הסרת העותקים המקומיים הושלמה. הקבצים נשארים ב־iCloud. מערכת ההפעלה עשויה לעדכן את המקום הזמין בהמשך." : "הקבצים הועברו לפח. השינוי מסתנכרן ל־iCloud ולמכשירים האחרים. בדוק את הפח ב־Finder לשחזור; פינוי מכסת הענן תלוי בעדכון ובמדיניות השמירה של iCloud.") : errors.joined(separator: "\n")
                self.alert = true; self.busy = false; self.scan()
                self.cleanupSucceeded = errors.isEmpty
            }
        }
        }
    }
}

struct CloudView: View {
    @ObservedObject private var model = CloudModel.shared
    @ObservedObject private var protection = ProtectionUI.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showScanDetails = false
    @State private var showSelectionTools = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("האחסון בענן").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("iCloud Drive · בוחרים מה נשאר במק")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if model.scanning {
                        Button { model.engine.cancel() } label: { Label("עצירת הסריקה", systemImage: "stop.fill") }
                    } else {
                        Button(action: model.scan) { Label(model.scanned ? "סריקה מחדש" : "סריקת iCloud", systemImage: "magnifyingglass") }
                            .buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.busy)
                    }
                }
                HStack(spacing: 10) {
                    cloudModeButton(localOnly: true, title: "פינוי מקום במק", icon: "internaldrive")
                    cloudModeButton(localOnly: false, title: "העברה לפח בענן", icon: "trash")
                }.disabled(model.busy)
                    .onChange(of: model.evict) { _ in model.selected = []; model.rebuild() }
                if model.scanned || model.busy {
                    FileTools(search: $model.search, sort: $model.sort)
                    HStack(spacing: 8) {
                        Toggle("הצעות לבדיקה", isOn: $model.suggestionsOnly).toggleStyle(.checkbox).disabled(model.busy)
                        if !model.search.isEmpty || model.suggestionsOnly {
                            Button("איפוס") { model.search = ""; model.suggestionsOnly = false; model.rebuild() }
                        }
                        Spacer(minLength: 0)
                        Button("כלי בחירה") { showSelectionTools = true }.disabled(model.busy)
                        Button { showScanDetails = true } label: { Label("פרטי סריקה", systemImage: "info.circle") }
                    }.font(.caption)
                    HStack(spacing: 6) {
                        if model.busy || model.preparingAI { ProgressView().controlSize(.mini) }
                        Text(model.scanning ? "סורק · \(model.scanProgress.found.formatted()) קבצים נמצאו" : "\(model.visible.count.formatted()) תוצאות מתוך \(model.items.count.formatted()) קבצים")
                        Spacer(minLength: 0)
                        if model.preparingAI { Button("ביטול הכנת AI") { model.cancelAI() } }
                        else { Button("דוח כיסוי") { model.showIssues = true }.disabled(!model.scanned) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(StudioButtonStyle()).fixedSize(horizontal: false, vertical: true)
            ScrollView {
            if !model.scanned && !model.busy {
                VStack(spacing: 14) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 42, weight: .light)).foregroundStyle(Palette.accent)
                        .frame(width: 88, height: 88).background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 28))
                    Text(model.evict ? "לפנות מקום בלי למחוק מהענן" : "לבחור מה להסיר מ־iCloud").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(model.evict ? "סורקים, בוחרים עותקים להסרה ומאשרים. הקבצים יישארו זמינים בענן." : "סורקים, בוחרים קבצים ומאשרים העברה לפח. ההסרה חלה גם במכשירים המסונכרנים.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Label("הסריקה ממפה בלבד — אף קובץ לא משתנה", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(Palette.accent)
                    Button(action: model.scan) { Label("נתחיל בסריקת iCloud", systemImage: "magnifyingglass") }
                        .buttonStyle(StudioButtonStyle(prominent: true))
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                    LazyVStack(spacing: 9) {
                        ForEach(model.pageItems) { item in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 12) {
                                Toggle("בחר \(item.title)", isOn: Binding(get: { model.selected.contains(item.id) }, set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })).labelsHidden().toggleStyle(AnimatedCheckStyle(title: "בחר \(item.title)")).disabled(model.busy || ProtectionStore.shared.isProtected(item.path) || (model.evict ? !item.canEvict : !item.canDelete))
                                Image(systemName: item.canEvict ? "icloud.and.arrow.down" : "icloud").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent)
                                    .frame(width: 42, height: 42)
                                    .background(LinearGradient(colors: [Palette.accent.opacity(0.16), Color.indigo.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.accent.opacity(0.15), lineWidth: 1))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text(item.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).environment(\.layoutDirection, .leftToRight)
                                    HStack(spacing: 8) {
                                        Text(URL(fileURLWithPath: item.path).pathExtension.isEmpty ? "קובץ" : URL(fileURLWithPath: item.path).pathExtension.uppercased())
                                            .font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                                        Text("\(size(item.logicalBytes)) בענן · \(size(item.localBytes)) במק").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    if model.evict && !item.canEvict { Text("אינו זמין להסרת עותק מקומי — לא הורד או לא סונכרן במלואו").font(.caption2).foregroundStyle(.orange) }
                                }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 12) {
                                Button("פרטים והצעה") { model.detail = item }.buttonStyle(StudioButtonStyle())
                                ProtectionControl(path: item.path) { model.selected.remove(item.id) }
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder").frame(width: 30, height: 30) }.buttonStyle(StudioButtonStyle()).help("הצג ב־Finder").accessibilityLabel("הצג את \(item.title) ב־Finder")
                                }
                            }.padding(12)
                            .studioPanel(radius: 15, accented: model.selected.contains(item.id))
                            .studioHover(radius: 15)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.selected.contains(item.id))
                        }
                        if model.scanned && !model.busy && model.visible.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: model.items.isEmpty ? "icloud.slash" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(Palette.accent)
                                Text(model.items.isEmpty ? "לא נמצאו קבצים נגישים" : "אין תוצאות מתאימות").font(.headline)
                                Text(model.items.isEmpty ? "בדוק ש־iCloud Drive פעיל ושיש לאפליקציה הרשאת גישה." : "נסה חיפוש אחר. קבצים מוגנים אינם מופיעים ברשימה.")
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                                if !model.search.isEmpty { Button("נקה חיפוש") { model.search = "" }.buttonStyle(StudioButtonStyle()) }
                            }.padding(28).frame(maxWidth: .infinity)
                        }
                    }
            }
            }
            HStack { Button("הקודם") { model.page -= 1 }.disabled(model.page == 0); Spacer(); Text("עמוד \(model.page+1) מתוך \(model.pageCount)").font(.caption).foregroundStyle(.secondary); Spacer(); Button("הבא") { model.page += 1 }.disabled(model.page+1 >= model.pageCount) }.buttonStyle(StudioButtonStyle())
            ResponsiveRow(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectionUpdating ? "מחשב בחירה…" : model.chosen.isEmpty ? "סמנו קבצים כדי להמשיך" : "\(model.chosen.count) קבצים נבחרו · \(size(model.amount)) משוער")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text(model.chosen.isEmpty ? (model.evict ? "המקור יישאר ב־iCloud" : "ההסרה תחול בכל המכשירים") : "בשלב הבא תוצג בקשת אישור לפני הפעולה")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.evict ? "סקירת הפינוי מהמק" : "סקירת ההעברה לפח") { model.confirm = true }.buttonStyle(StudioButtonStyle(prominent: true)).tint(model.evict ? Palette.accent : .red).disabled(model.chosen.isEmpty || model.busy || model.selectionUpdating || model.preparingAI)
            }
            .padding(10)
            .studioPanel(radius: 14, accented: !model.chosen.isEmpty)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.chosen.isEmpty)
        }.frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground())
        .onChange(of: protection.revision) { _ in model.protectionsChanged() }
        .sheet(isPresented: $showSelectionTools) {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("כלי בחירה").font(.title2.bold()); Spacer(); Button("סגור") { showSelectionTools = false } }
                Text("בחרו קבצים לבדיקה. הפעולה עצמה תתבצע רק אחרי סקירה ואישור.").foregroundStyle(.secondary)
                if model.evict {
                    Button("בחירת כל העותקים הזמינים בתוצאות החיפוש") {
                        model.selected.formUnion(model.visible.filter { $0.canEvict && !ProtectionStore.shared.isProtected($0.path) }.map(\.id))
                        showSelectionTools = false
                    }.disabled(model.busy || model.visible.isEmpty)
                    Text("הבחירה כוללת את כל עמודי התוצאות, ורק עותקים מסונכרנים הזמינים להסרה מהמק.").font(.caption).foregroundStyle(.secondary)
                }
                Button("ניקוי הבחירה") { model.selected = []; showSelectionTools = false }
                    .disabled(model.busy || model.selected.isEmpty)
                Divider()
                Button { showSelectionTools = false; model.openAI() } label: { Label("בחירה בעזרת AI", systemImage: "sparkles") }
                    .disabled(model.busy || !model.scanned || model.preparingAI)
            }.padding(24).buttonStyle(StudioButtonStyle())
                .responsiveSheet(width: 570).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $showScanDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("פרטי הסריקה והפעולה").font(.title2.bold())
                    Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
                    if model.scanning { ScanActivityPanel(progress: model.scanProgress, startedAt: model.startedAt) }
                    Text(model.evict ? "רק קבצים שהורדו והועלו במלואם זמינים להסרת העותק המקומי. אפשר להוריד אותם שוב מ־iCloud בעת הצורך. המקור נשאר בענן ואין שינוי במכסת הענן." : "הפעולה מעבירה לפח קבצים מ־iCloud Drive. הם יוסרו גם מהמכשירים המסונכרנים. האפליקציה אינה מרוקנת את הפח; אין הבטחה לפינוי מיידי של מכסת הענן.")
                    Label("מיפוי קבצים אינו המלצה למחיקה", systemImage: "checkmark.shield")
                    Text("כולל iCloud Drive ותיקיות מסמכים של יישומי iCloud הנגישות במק — ללא iCloud Photos, דואר או גיבויי iPhone. מכסת הענן הכוללת אינה מוצגת.")
                    Text("הסריקה קוראת מטא־נתונים בלבד, ללא הורדת תוכן קבצים. הרשאות וזמינות ספק הענן עשויות להגביל את הכיסוי. הצעות לבדיקה אינן בוחרות קבצים אוטומטית. למחיקה מהענן בוחרים קבצים אישית; לפני הפעולה יוצגו כל הקבצים לאישור.")
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                HStack { Spacer(); Button("סגור") { showScanDetails = false }.buttonStyle(StudioButtonStyle(prominent: true)) }.padding(14).background(.ultraThinMaterial)
            }.responsiveSheet(width: 650, height: 540).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $model.ai) {
            AIAssistantView(candidates:model.aiCandidates,source:model.aiSource) { model.selected = $0 }
        }
        .sheet(isPresented: $model.showIssues) {
            ScrollView { VStack(alignment:.leading,spacing:16) {
                Text("דוח כיסוי iCloud").font(.title2.bold())
                Text("סריקת מטא־נתונים של מסמכי iCloud ויישומים, כולל מוסתרים וחבילות. אין הורדת תוכן קבצים. הרשאות וזמינות ספק הענן עשויות להגביל את המיפוי.").font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment:.leading,spacing:12) { ForEach(Array(model.issues.enumerated()),id:\.offset) { _,issue in VStack(alignment:.leading) { Text(issue.reason).font(.caption); Text(issue.path).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled) } } }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20) }.safeAreaInset(edge: .bottom) {
                HStack { Spacer(); Button("סגור") { model.showIssues = false }.buttonStyle(StudioButtonStyle(prominent: true)) }.padding(14).background(.ultraThinMaterial)
            }.responsiveSheet(width:650, height: 540).preferredColorScheme(.dark).environment(\.layoutDirection,.rightToLeft)
        }
        .sheet(item: $model.detail) { item in
            cloudDetails(item)
        }
        .sheet(isPresented: $model.confirm) {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                Text(model.evict ? "להסיר את העותקים הבאים מהמק בלבד?" : "להעביר את הקבצים הבאים לפח בכל המכשירים?").font(.title2.bold())
                Text("\(model.chosen.count) קבצים · \(size(model.amount)) משוער").font(.headline)
                Text(model.evict ? "המקור נשאר ב־iCloud וניתן להורדה מחדש. מכסת הענן לא תשתנה." : "ההסרה מסתנכרנת ל־iCloud ולכל המכשירים. האפליקציה אינה מרוקנת את הפח. לשחזור בדקו את הפח ב־Finder; זמינות השחזור ופינוי המכסה תלויים ב־iCloud.").foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 12) { ForEach(model.chosen) { item in
                    VStack(alignment: .leading) {
                        Text(item.title).bold()
                        Text(item.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Text("גודל קובץ: \(size(item.logicalBytes)) · במק: \(size(item.localBytes))").font(.caption)
                    }
                } }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20) }.safeAreaInset(edge: .bottom) {
                ResponsiveRow {
                    Button("ביטול — להשאיר את הקבצים") { model.confirm = false }
                    Spacer()
                    Button(model.evict ? "מאשר הסרה מהמק בלבד" : "מאשר העברה לפח מכל המכשירים", role: .destructive) { model.confirm = false; model.act() }
                        .disabled(model.busy || model.selectionUpdating || model.chosen.isEmpty)
                }
                .padding(14).background(.ultraThinMaterial)
            }.responsiveSheet(width: 700, height: 620).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
        }
        .alert("תוצאת הפעולה", isPresented: $model.alert) { Button("אישור", role: .cancel) {} } message: { Text(model.message) }
    }

    private func cloudDetails(_ item: CloudItem) -> some View {
        let suggestion = CloudSuggestion.evaluate(item)
        return ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("פרטי קובץ והצעת ניקוי").font(.title2.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    Text(item.path).font(.system(size: 12, design: .monospaced)).environment(\.layoutDirection, .leftToRight)
                    Text("סוג: \(URL(fileURLWithPath: item.path).pathExtension.isEmpty ? "ללא סיומת" : URL(fileURLWithPath: item.path).pathExtension)")
                    Text("גודל קובץ בענן: \(size(item.logicalBytes)) · הקצאה מקומית משוערת: \(size(item.localBytes))")
                    Text("שינוי אחרון: \(item.modified == .distantPast ? "לא ידוע" : item.modified.formatted(date: .long, time: .shortened))")
                    Text(item.canEvict ? "עותק מקומי מסונכרן זמין להסרה" : "הסרת עותק מקומי אינה זמינה לפי הסריקה")
                    Text(item.canDelete ? "זמין לבחירה ידנית למחיקה מהענן" : "לעיון בלבד — תיקיית יישום, מטא־נתונים חסרים או תוכן חבילה")
                    Divider()
                    Text(suggestion.title).font(.headline)
                    Text(suggestion.reason)
                    Text(suggestion.uncertainty).foregroundStyle(.orange)
                    Text(suggestion.question).font(.headline)
                    Text(model.evict ? "הפעולה הנבחרת תסיר רק את העותק במק; המקור יישאר בענן ולא תפנה מכסת iCloud." : "הפעולה הנבחרת תעביר לפח גם ב־iCloud ובמכשירים המסונכרנים. הגודל אינו הבטחה לפינוי מיידי של המכסה.")
                    Text("לא נקרא תוכן הקובץ. לא נבדקו שימוש אחרון, כפילות תוכן או גיבוי. לפני פעולה הנתונים וההגנות נבדקים מחדש.").font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled)
        }.padding(20) }.safeAreaInset(edge: .bottom) {
            ResponsiveRow {
                Button("סגור — ללא שינוי בבחירה") { model.detail = nil }
                Button("הצג ב־Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                Spacer()
                Button(model.evict ? "בחר להסרת עותק מהמק" : "בחר להעברה לפח מ־iCloud") { model.selected.insert(item.id); model.detail = nil }
                    .disabled(model.busy || ProtectionStore.shared.isProtected(item.path) || (model.evict ? !item.canEvict : !item.canDelete))
            }
            .padding(14).background(.ultraThinMaterial)
        }.responsiveSheet(width: 740, height: 690).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
    }

    private func cloudModeButton(localOnly: Bool, title: String, icon: String) -> some View {
        let selected = model.evict == localOnly
        let color = localOnly ? Palette.accent : Color.orange
        return Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { model.evict = localOnly } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 18)).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(localOnly ? "המקור נשאר ב־iCloud" : "ההסרה חלה בכל המכשירים")
                        .font(.system(size: 11)).foregroundStyle(selected ? color.opacity(0.85) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.caption)
            }
            .foregroundStyle(selected ? color : Color.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? color.opacity(0.10) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? color.opacity(0.45) : Color.white.opacity(0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).studioHover(radius: 8).accessibilityAddTraits(selected ? .isSelected : [])
    }

}
