import SwiftUI
import AppKit
import UniformTypeIdentifiers

private final class AIWorkEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ generation: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == generation }
}

@MainActor final class AIFlowModel: ObservableObject {
    let candidates: [AICandidate]
    let source: AISource
    private let storageURL: URL
    @Published var session: AIExportSession?
    @Published var groupsByID: [String: AIExportGroup] = [:]
    @Published var onlyTemporary = true
    @Published var privatePaths = false
    @Published var response = "" { didSet { review = nil; eligibleCount = 0; blockedCount = 0 } }
    @Published var review: AIReview?
    @Published var eligibleCount = 0
    @Published var blockedCount = 0
    @Published var error = ""
    @Published var notice = ""
    @Published var working = false
    @Published var step = 1
    private let queue = DispatchQueue(label: "storage.ai.work", qos: .userInitiated)
    private let epoch = AIWorkEpoch()

    init(candidates:[AICandidate],source:AISource,storageURL:URL? = nil) {
        self.candidates = candidates; self.source = source
        self.storageURL = storageURL ?? Self.sessionURL(source)
        onlyTemporary = source == .local
        let generation = begin(), epoch = self.epoch, storage = self.storageURL
        queue.async { [weak self] in
            guard epoch.current(generation) else { return }
            let saved: AIExportSession?
            if let data = try? Data(contentsOf: storage),
               let decoded = try? JSONDecoder().decode(AIExportSession.self, from: data), decoded.source == source { saved = decoded }
            else { saved = nil }
            let groups = Dictionary((saved?.groups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async {
                guard let self, epoch.current(generation) else { return }
                self.session = saved; self.groupsByID = groups
                if let saved { self.privatePaths = saved.includePrivatePaths }
                self.working = false
            }
        }
    }
    nonisolated static func sessionURL(_ source:AISource) -> URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("StorageBreath/AI",isDirectory:true).appendingPathComponent(source.rawValue + "-last-session.json")
    }
    nonisolated static func protectionCheck() -> (String)->Bool {
        let rules = ProtectionStore.shared.entries()
        return { path in rules.contains { $0.path == "/" || path == $0.path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") } }
    }
    private func begin() -> Int { working = true; error = ""; notice = ""; return epoch.advance() }
    func cancel() { _ = epoch.advance(); working = false }
    private func fail(_ error: Error, generation: Int) {
        guard epoch.current(generation) else { return }
        self.error = error.localizedDescription; working = false
    }
    func prepare(andCopy:Bool) {
        guard !working else { return }
        let candidates = self.candidates, source = self.source, privatePaths = self.privatePaths, onlyTemporary = self.onlyTemporary
        let generation = begin(), epoch = self.epoch, storage = self.storageURL
        queue.async {
            do {
                guard epoch.current(generation) else { return }
                let blocked = Self.protectionCheck()
                var input: [AICandidate] = []
                for candidate in candidates {
                    guard epoch.current(generation) else { return }
                    if candidate.allowed && (!onlyTemporary || CleanupAssessment.assess(candidate,source:source).recommendationEligible) && !blocked(candidate.path) { input.append(candidate) }
                }
                guard !input.isEmpty else { throw AIExchangeError.invalid("לא נמצאו תוצרים מוכרים וישנים המתאימים לבחירה שמרנית. אפשר להרחיב את הדוח לבדיקה אישית; הדבר אינו מתיר סימון אוטומטי.") }
                let created = try AIExportSession.create(candidates:input,source:source,includePrivatePaths:privatePaths)
                guard epoch.current(generation) else { return }
                let text = andCopy ? created.prompt() + "\n\n" + (try created.payload()) : nil
                let groups = Dictionary(uniqueKeysWithValues: created.groups.map { ($0.id, $0) })
                guard epoch.current(generation) else { return }
                let encoded = try JSONEncoder().encode(created)
                guard epoch.current(generation) else { return }
                try FileManager.default.createDirectory(at:storage.deletingLastPathComponent(),withIntermediateDirectories:true)
                try encoded.write(to:storage,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:storage.path)
                DispatchQueue.main.async {
                    guard epoch.current(generation) else { return }
                    self.session = created; self.groupsByID = groups; self.response = ""; self.review = nil; self.working = false; self.step = 2
                    if let text { self.copy(text); self.notice = "ההנחיה והדוח הועתקו יחד. הדבק ב־AI לבחירתך ובקש תשובת JSON." }
                }
            } catch { DispatchQueue.main.async { self.fail(error, generation:generation) } }
        }
    }
    func copy(_ text:String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
    func copySession() {
        guard !working, let session else { return }
        let generation = begin(), epoch = self.epoch
        queue.async {
            do {
                guard epoch.current(generation) else { return }
                let text = session.prompt() + "\n\n" + (try session.payload())
                DispatchQueue.main.async {
                    guard epoch.current(generation) else { return }
                    self.copy(text); self.notice = "הועתק. אין צורך במפתח API או בחיבור חשבון."; self.working = false
                }
            } catch { DispatchQueue.main.async { self.fail(error, generation:generation) } }
        }
    }
    func saveReport() {
        guard !working else { return }
        guard let session else { error = "יש ליצור דוח תחילה."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "storage-ai-report.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let generation = begin(), epoch = self.epoch
        queue.async {
            do {
                guard epoch.current(generation) else { return }
                let payload = try session.payload()
                guard epoch.current(generation) else { return }
                try payload.write(to:url,atomically:true,encoding:.utf8)
                DispatchQueue.main.async {
                    guard epoch.current(generation) else { return }
                    self.notice = "דוח JSON נשמר. ההנחיות זמינות בכפתור ההעתקה."; self.working = false
                }
            } catch { DispatchQueue.main.async { self.fail(error, generation:generation) } }
        }
    }
    func loadResponse() {
        guard !working else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json,.plainText]
        guard panel.runModal() == .OK, let url = panel.url, let session else { return }
        let generation = begin()
        runReview(session:session,generation:generation,apply:nil) {
            let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
            // Bound the actual read too: the file may grow after its metadata was checked.
            let data = try handle.read(upToCount:10*1024*1024+1) ?? Data()
            guard data.count <= 10*1024*1024 else { throw AIExchangeError.invalid("הקובץ גדול מ־10MB.") }
            guard let text = String(data:data,encoding:.utf8) else { throw AIExchangeError.invalid("הקובץ אינו טקסט UTF-8 תקין.") }
            return text
        }
    }
    func pasteAndValidate() {
        guard !working else { return }
        guard let pasted = NSPasteboard.general.string(forType:.string) else { error = "לוח ההעתקה אינו מכיל טקסט."; return }
        validate(text:pasted)
    }
    func validate() { validate(text:response) }
    private func validate(text:String) {
        guard !working else { return }
        guard let session else { error = "צריך ליצור דוח או לטעון את הסשן האחרון לפני ייבוא תשובה."; return }
        let generation = begin()
        runReview(session:session,generation:generation,apply:nil) { text }
    }
    func apply(_ completion: @escaping (Set<String>) -> Void) {
        guard !working, let session else { return }
        let text = response, generation = begin()
        // Revalidate against current protection rules off the UI thread before applying.
        runReview(session:session,generation:generation,apply:completion) { text }
    }
    private func runReview(session:AIExportSession,generation:Int,apply:((Set<String>)->Void)?,read:@escaping () throws -> String) {
        let candidates = self.candidates, epoch = self.epoch
        queue.async {
            do {
                guard epoch.current(generation) else { return }
                let text = try read()
                guard epoch.current(generation) else { return }
                guard text.utf8.count <= 10*1024*1024 else { throw AIExchangeError.invalid("התשובה גדולה מ־10MB.") }
                let checked = try session.review(response:text,current:candidates,protected:Self.protectionCheck())
                let ids = Set(checked.eligibleIDs), blocked = checked.blockedCount
                DispatchQueue.main.async {
                    guard epoch.current(generation) else { return }
                    self.response = text; self.review = checked; self.eligibleCount = ids.count; self.blockedCount = blocked
                    self.step = 3; self.working = false
                    apply?(ids)
                }
            } catch { DispatchQueue.main.async { self.fail(error, generation:generation) } }
        }
    }
}

struct AIAssistantView: View {
    @StateObject private var flow: AIFlowModel
    @Environment(\.dismiss) private var dismiss
    let onApply: (Set<String>) -> Void
    @MainActor init(candidates:[AICandidate],source:AISource,onApply:@escaping(Set<String>)->Void) {
        _flow = StateObject(wrappedValue:AIFlowModel(candidates:candidates,source:source)); self.onApply = onApply
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment:.leading,spacing:7) {
                    Label("עזרה בבחירת קבצים עם AI",systemImage:"sparkles").font(.system(size:23,weight:.bold,design:.rounded)).foregroundStyle(Palette.accent)
                    Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("סגור") { flow.cancel(); dismiss() }.buttonStyle(StudioButtonStyle())
            }
            HStack(spacing: 6) { step("1","העתק ל־AI",active:flow.step == 1); step("2","הדבק תשובה",active:flow.step == 2); step("3","סקור וסמן",active:flow.step == 3) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button { flow.prepare(andCopy:true) } label: { Label("צור והעתק דוח", systemImage:"doc.on.doc") }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(flow.working)
                    Button("הדבק ובדוק") { flow.pasteAndValidate() }.buttonStyle(StudioButtonStyle()).disabled(flow.working || flow.session == nil)
                    Button("ייבא JSON…") { flow.loadResponse() }.buttonStyle(StudioButtonStyle()).disabled(flow.working || flow.session == nil)
                }
                HStack(spacing: 12) {
                    Button("בדוק תשובה") { flow.validate() }.disabled(flow.response.isEmpty)
                    Button("העתק דוח אחרון") { flow.copySession() }.disabled(flow.session == nil || flow.session?.includePrivatePaths != flow.privatePaths)
                    Button("שמור דוח JSON…") { flow.saveReport() }.disabled(flow.session == nil || flow.session?.includePrivatePaths != flow.privatePaths)
                }.buttonStyle(StudioButtonStyle()).font(.caption).disabled(flow.working)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    VStack(alignment:.leading,spacing:12) {
                        Text("העתיקו דוח והדביקו בשיחת AI לבחירתכם").font(.headline)
                        Text("הדוח כולל קבוצות קבצים והנחיה מוכנה. שום מידע לא נשלח אוטומטית; אתם מעתיקים ל־AI ומחזירים לכאן את התשובה.").font(.caption).foregroundStyle(.secondary)
                        if flow.source == .local { Toggle("כלול בדוח רק מועמדי ניקוי שמרניים",isOn:$flow.onlyTemporary).disabled(flow.working) }
                        Toggle("כלול שמות קבצים ונתיבים פרטיים בדוח",isOn:$flow.privatePaths).disabled(flow.working)
                        Text(flow.privatePaths ? "הדוח יכיל שמות ונתיבים שעשויים לחשוף מידע אישי. תוכן הקבצים לא נכלל." : "ברירת המחדל משתפת סיכום קבוצות בלבד, ללא שמות קבצים או נתיבים. קבצים מוגנים מוחרגים.").font(.caption2).foregroundStyle(flow.privatePaths ? .orange : .secondary)
                    }.padding(16).studioPanel()
                    VStack(alignment:.leading,spacing:12) {
                        Text("החזירו לכאן את תשובת ה־AI").font(.headline)
                        TextEditor(text:$flow.response).font(.system(size:11,design:.monospaced)).environment(\.layoutDirection,.leftToRight).frame(height:130).scrollContentBackground(.hidden).padding(9).background(.black.opacity(0.20),in:RoundedRectangle(cornerRadius:11)).disabled(flow.working)
                    }.padding(16).studioPanel()
                    if let review = flow.review {
                        LazyVStack(alignment:.leading,spacing:12) {
                            HStack { Text("\(flow.eligibleCount.formatted()) קבצים מוכנים לסימון").font(.headline).foregroundStyle(Palette.accent); Spacer(); Text("\(flow.blockedCount) הוחרגו בבדיקות").font(.caption).foregroundStyle(.secondary) }
                            Text("המלצת AI אינה מספיקה לסימון: נדרשים גם תנאי הניקוי המקומיים וביטחון של 90% לפחות. קבצים אישיים, הורדות חלקיות ומידע לא מזוהה נשארים לבדיקה אישית. מחיקה מהענן אינה מסומנת לפי קבוצות.").font(.caption2).foregroundStyle(.secondary)
                            ForEach(review.rows) { row in
                                let group = flow.groupsByID[row.id]
                                HStack(alignment:.top,spacing:10) {
                                    Image(systemName:row.action == "select" ? "checkmark.circle" : "hand.raised").foregroundStyle(row.action == "select" ? Palette.accent : .secondary)
                                    VStack(alignment:.leading,spacing:5) { if let group { Text("\(group.category) · \(group.fileExtension) · \(group.ageBucket)").font(.caption.bold()) }; Text(row.reason).font(.caption); if !row.localReason.isEmpty { Text("בדיקה מקומית: " + row.localReason).font(.caption).foregroundStyle(.orange) }; Text("\(row.action) · \(Int(row.confidence*100))% · \(row.eligibleIDs.count) קבצים · \(size(row.bytes))").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).studioPanel(radius: 14).studioHover(radius: 14)
                            }
                        }
                    }
                }
            }
            if flow.working { HStack { ProgressView().controlSize(.small); Text("מכין ובודק…").font(.caption) } }
            if !flow.error.isEmpty { Text(flow.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !flow.notice.isEmpty { Text(flow.notice).font(.caption).foregroundStyle(Palette.accent) }
            ResponsiveRow {
                Text("הייבוא מסמן קבצים בלבד. העברה לפח דורשת סקירה ואישור נוסף.").font(.caption2).foregroundStyle(.secondary)
                Button("החלף בחירה בהמלצות") {
                    flow.apply { ids in onApply(ids); dismiss() }
                }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(flow.review == nil || flow.working || flow.eligibleCount == 0)
            }.padding(14).studioPanel(radius: 14)
        }.padding(22).responsiveSheet(width:820,height:710).background(AmbientBackground()).preferredColorScheme(.dark).environment(\.layoutDirection,.rightToLeft).onDisappear { flow.cancel() }
    }
    var sourceLabel: String {
        switch flow.source {
        case .local: return "ניתוח האחסון המקומי · ההמלצות מיועדות לבחירה לפני העברה לפח"
        case .cloudEvict: return "iCloud · המלצות להסרת עותקים מקומיים תוך שמירת המקור בענן"
        case .cloudDelete: return "iCloud · המלצות לבדיקה לפני העברה לפח וסנכרון ההסרה למכשירים"
        }
    }
    func step(_ number:String,_ title:String,active:Bool)->some View { HStack(spacing:6) { Text(number).font(.caption.bold()).frame(width:25,height:25).background(active ? Palette.accent : .white.opacity(0.07),in:Circle()); Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.85).foregroundStyle(active ? .white : .secondary) }.padding(8).frame(maxWidth:.infinity).background(active ? Palette.accent.opacity(0.08) : .clear,in:RoundedRectangle(cornerRadius:10)) }
}
