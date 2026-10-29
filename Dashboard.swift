import SwiftUI
import AppKit
import Combine


final class FilterEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ expected:Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == expected }
}
private enum FilterCancelled: Error { case cancelled }

enum ExplorerSort: String, CaseIterable, Identifiable {
    case largest = "הגדולים קודם", smallest = "הקטנים קודם", name = "לפי שם", oldest = "הישנים קודם", newest = "החדשים קודם"
    var id: String { rawValue }
}
extension DeepFile {
    var aiCandidate: AICandidate {
        AICandidate(id:id,path:path,title:title,category:category,bytes:bytes,modified:modified,temporary:isTemporary,allowed:canTrash,reason:reason)
    }
    var cleanupAssessment: CleanupAssessment { CleanupAssessment.assess(aiCandidate,source:.local) }
}

@MainActor final class ExplorerModel: ObservableObject {
    @Published var files: [DeepFile] = [] // In-memory fixtures only; production uses SQLite pages.
    @Published var filtered: [DeepFile] = []
    @Published var filtering = false
    @Published var issues: [DeepIssue] = []
    @Published var selected: Set<String> = [] { didSet { refreshSelection() } }
    @Published var focus: DeepFile?
    @Published var ai = false
    @Published var aiCandidates: [AICandidate] = []
    @Published var preparingAI = false
    @Published var performance: ScanPerformance = .background
    @Published var lastWorkers = 0
    @Published var scanElapsed: TimeInterval = 0
    @Published private(set) var loadingIndex = false
    @Published var scanning = false
    @Published var paused = false
    @Published var cleaning = false
    @Published var completed = false
    @Published var cancelled = false
    @Published var progress = ScanProgress(stage:"מוכן",currentPath:"",inspected:0,found:0,bytes:0)
    @Published var startedAt = Date()
    @Published var scope = "home"
    @Published var customRoot: URL?
    @Published var query = "" { didSet { scheduleFilter() } }
    @Published var section = "הכול" { didSet { page = 0; rebuild() } }
    @Published var sort: ExplorerSort = .largest { didSet { page = 0; rebuild() } }
    @Published var minimum: Int64 = 0 { didSet { page = 0; rebuild() } }
    @Published var age = 0 { didSet { page = 0; rebuild() } }
    @Published var page = 0 { didSet { if database != nil && oldValue != page { rebuild() } } }
    @Published var matchCount = 0
    @Published var inventoryCount = 0
    @Published var issueTotal = 0
    @Published var issueOffset = 0
    @Published var resumeAvailable = false
    @Published var storageError = ""
    @Published var cloud = false
    @Published var coverage = false
    @Published var confirm = false
    @Published var result = false
    @Published var resultText = ""
    @Published var resultErrors: [String] = []
    @Published var removedCount = 0
    @Published var scannedRoots = ""
    @Published var cleanupDone = 0
    @Published var cleanupTotal = 0
    @Published var cleanupPath = ""
    @Published var temporaryCount = 0
    @Published var temporaryBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var categoryStats: [(String,Int64)] = []
    @Published var selectionNotice = ""
    @Published var selectionPreview: [DeepFile] = []
    @Published var selectionCount = 0
    @Published var selectionBytes: Int64 = 0
    private(set) var database: InventoryDatabase?
    private(set) var engine: DeepScanEngine
    private let inMemory: Bool
    private var fileLookup: [String:DeepFile] = [:]
    private let filterEpoch = FilterEpoch()
    private let selectionEpoch = FilterEpoch()
    private let filterQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q }()
    private let ioQueue = DispatchQueue(label:"storage.inventory.ui",qos:.utility)
    private let aiQueue = DispatchQueue(label:"storage.inventory.ai",qos:.utility)
    private let selectionQueue = DispatchQueue(label:"storage.inventory.selection",qos:.userInitiated)
    private var refreshingDisk = false
    private var refreshPending = false
    private var filterGeneration = 0
    private var lastRefresh = Date.distantPast
    private var searchWork: DispatchWorkItem?
    private var pendingStart: Bool?
    private let cleanupGate = CleanupGate()
    private let aiEpoch = FilterEpoch()
    let pageSize = 100
    init(database:InventoryDatabase? = nil,inMemory:Bool = false) {
        self.inMemory = inMemory
        self.database = database
        self.engine = DeepScanEngine(database:database)
        if !inMemory, database == nil {
            loadingIndex = true; filtering = true
            ioQueue.async {
                do {
                    let url = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("StorageBreath/Inventory.sqlite")
                    let opened = try InventoryDatabase(url:url)
                    DispatchQueue.main.async {
                        self.database = opened; self.engine = DeepScanEngine(database:opened); self.loadingIndex = false
                        self.refreshDisk(restoreScope:true)
                    }
                } catch { DispatchQueue.main.async { self.loadingIndex = false; self.filtering = false; self.storageError = error.localizedDescription } }
            }
        } else if !inMemory { refreshDisk(restoreScope:true) }
    }

    var busy: Bool { loadingIndex || scanning || cleaning }
    var pageCount: Int { max(1,((database == nil ? filtered.count : matchCount)+pageSize-1)/pageSize) }
    var pageFiles: [DeepFile] { if database != nil { return filtered }; let lower = min(page*pageSize,filtered.count); return Array(filtered[lower..<min(lower+pageSize,filtered.count)]) }
    var chosen: [DeepFile] { database != nil ? selectionPreview : selected.compactMap { fileLookup[$0] }.sorted { $0.path < $1.path } }
    var chosenBytes: Int64 { database != nil ? selectionBytes : chosen.reduce(0) { $0+$1.bytes } }
    var chosenCount: Int { database != nil ? selectionCount : selected.count }
    var roots: [URL] { if scope == "mac" { return [URL(fileURLWithPath:"/")] }; if scope == "custom",let customRoot { return [customRoot] }; return DeepScanEngine.defaultRoots }
    func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "בחר תיקייה לסריקה"; if panel.runModal() == .OK,let url = panel.url { customRoot = url; scope = "custom" } }
    func requestScan(resume:Bool = false) {
        if !PermissionSetup.shared.prepared { pendingStart = resume; PermissionSetup.shared.show = true }
        else { scan(resume:resume) }
    }
    func permissionsDone() { if let resume = pendingStart { pendingStart = nil; scan(resume:resume) } }
    func scheduleFilter() { filterGeneration = filterEpoch.advance(); filterQueue.cancelAllOperations(); filtering = true; searchWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.page = 0; self?.rebuild() }; searchWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work) }
    func request() -> InventoryQuery {
        var value = InventoryQuery(); value.search = query; value.section = section; value.sort = String(describing:sort); value.minimum = minimum; value.ageDays = age; value.offset = page*pageSize; value.limit = pageSize; value.protected = ProtectionStore.shared.entries(); return value
    }
    func rebuild() {
        guard let database else { if inMemory { rebuildMemory() }; return }
        let request = request(), epoch = filterEpoch
        filterGeneration = epoch.advance(); let generation = filterGeneration
        filterQueue.cancelAllOperations(); filtering = true
        filterQueue.addOperation {
            guard epoch.current(generation) else { return }
            do {
                let result = try database.query(request:request,isCancelled:{ !epoch.current(generation) })
                guard epoch.current(generation) else { return }
                DispatchQueue.main.async {
                    guard generation == self.filterGeneration else { return }
                    self.filtered = result.files; self.matchCount = result.total; self.filtering = false
                    if self.page >= self.pageCount { self.page = self.pageCount-1 }
                }
            } catch { DispatchQueue.main.async { guard generation == self.filterGeneration else { return }; self.filtering = false; self.storageError = error.localizedDescription } }
        }
    }
    func refreshDisk(restoreScope:Bool = false) {
        guard let database else { return }
        if refreshingDisk { refreshPending = true; return }
        refreshingDisk = true
        ioQueue.async {
            do {
                let stats = try database.stats(), count = try database.issueCount(), state = try database.scanState(), directories = try database.directoryProgress()
                DispatchQueue.main.async {
                    self.refreshingDisk = false
                    self.inventoryCount = stats.count; self.totalBytes = stats.bytes; self.temporaryCount = stats.temporaryCount; self.temporaryBytes = stats.temporaryBytes; self.categoryStats = stats.categories; self.issueTotal = count
                    if !self.scanning {
                        self.progress = ScanProgress(stage:"אינדקס שמור",currentPath:"",inspected:stats.count,found:stats.count,bytes:stats.bytes,completedDirectories:directories.completed,discoveredDirectories:directories.discovered)
                    }
                    self.resumeAvailable = state?.incomplete == true && (state?.pendingCount ?? 0)>0
                    if restoreScope,let state {
                        self.scannedRoots = state.roots.map(\.path).joined(separator:" · ")
                        if state.roots.count == 1,let root = state.roots.first { if root.path == "/" { self.scope = "mac" } else { self.customRoot = root; self.scope = "custom" } }
                        self.completed = true; self.cancelled = state.incomplete
                    }
                    self.rebuild()
                    if self.refreshPending { self.refreshPending = false; self.refreshDisk() }
                }
            } catch { DispatchQueue.main.async { self.refreshingDisk = false; self.refreshPending = false; self.storageError = error.localizedDescription; self.filtering = false } }
        }
    }
    func summarize() {
        if database != nil { refreshDisk(); return }
        fileLookup = Dictionary(files.map { ($0.id,$0) },uniquingKeysWith:{ _,new in new })
        inventoryCount = files.count; temporaryCount = files.filter(\.isTemporary).count; temporaryBytes = files.filter(\.isTemporary).reduce(0) { $0+$1.bytes }; totalBytes = files.reduce(0) { $0+$1.bytes }
        var sums:[String:Int64] = [:]; for file in files { sums[file.category,default:0] += file.bytes }; categoryStats = sums.sorted { $0.value>$1.value }.map { ($0.key,$0.value) }
    }
    func scan(resume:Bool = false) {
        guard !busy,!preparingAI else { return }
        guard database != nil || inMemory else { storageError = "אין אינדקס זמין; הסריקה לא התחילה כדי למנוע עומס זיכרון."; return }
        filterGeneration = filterEpoch.advance(); filterQueue.cancelAllOperations(); selected = []; focus = nil; page = 0; completed = false; cancelled = false; removedCount = 0; scanning = true; paused = false; startedAt = Date(); lastRefresh = .distantPast
        let worker = engine, chosenRoots = roots, speed = performance, database = self.database
        var excluded = PermissionSetup.shared.excludedPaths
        if scope == "custom",let root = customRoot { excluded.removeAll { root.path == $0 || root.path.hasPrefix($0+"/") } }
        scannedRoots = chosenRoots.map(\.path).joined(separator:" · ")
        progress = ScanProgress(stage:resume ? "ממשיך מנקודת השמירה" : "מכין סריקה ברקע",currentPath:"",inspected:0,found:inventoryCount,bytes:totalBytes)
        DispatchQueue.global(qos:.background).async {
            let report = worker.scan(roots:chosenRoots,performance:speed,database:database,resume:resume,excludedPaths:excluded,progress:{ update in
                DispatchQueue.main.async {
                    self.progress = update
                    if Date().timeIntervalSince(self.lastRefresh)>10 { self.lastRefresh = Date(); self.refreshDisk() }
                }
            })
            DispatchQueue.main.async {
                self.lastWorkers = report.workers; self.scanElapsed = report.elapsed; self.scanning = false; self.paused = false; self.completed = true; self.cancelled = report.cancelled
                if database != nil { if let issue = report.issues.first { self.storageError = issue.reason }; self.refreshDisk() } else { self.files = report.files; self.issues = report.issues; self.summarize(); self.rebuild() }
            }
        }
    }
    func togglePause() { if paused { engine.resume() } else { engine.pause() }; paused.toggle() }
    func refreshSelection() {
        guard let database else { return }
        let generation = selectionEpoch.advance(), epoch = selectionEpoch, paths = Array(selected), protected = ProtectionStore.shared.entries()
        if paths.isEmpty { selectionPreview = []; selectionCount = 0; selectionBytes = 0; return }
        selectionQueue.async {
            guard epoch.current(generation) else { return }
            do { let result = try database.selected(paths:paths,limit:100,protected:protected,isCancelled:{ !epoch.current(generation) }); DispatchQueue.main.async { guard epoch.current(generation) else { return }; self.selectionPreview = result.files; self.selectionCount = result.total; self.selectionBytes = result.bytes } }
            catch { DispatchQueue.main.async { guard epoch.current(generation) else { return }; self.storageError = error.localizedDescription } }
        }
    }
    func selectVisible() {
        selectionNotice = ""
        guard let database else {
            let ids = filtered.filter { $0.canTrash && $0.cleanupAssessment.recommendationEligible }.map(\.id)
            selected.formUnion(ids)
            selectionNotice = ids.isEmpty ? "לא נמצאו מועמדי ניקוי שמרניים במסנן. יתר הקבצים נשארים לבדיקה אישית." : "נבחרו רק תוצרים מוכרים וישנים לבדיקה; זו אינה הוכחה שאינם בשימוש."
            return
        }
        let request = request(), epoch = filterEpoch, generation = filterGeneration
        let selectionGeneration = selectionEpoch.advance(), selectionToken = selectionEpoch
        filtering = true
        selectionQueue.async {
            do {
                var ids: [String] = []
                let now = Date()
                try database.forEachFile(request:request,isCancelled:{ !epoch.current(generation) || !selectionToken.current(selectionGeneration) }) { file in
                    if file.canTrash && CleanupAssessment.assess(file.aiCandidate,source:.local,now:now).recommendationEligible { ids.append(file.id) }
                }
                let result = ids
                DispatchQueue.main.async {
                    guard epoch.current(generation), selectionToken.current(selectionGeneration) else { return }
                    self.selected.formUnion(result); self.filtering = false
                    self.selectionNotice = result.isEmpty ? "לא נמצאו מועמדי ניקוי שמרניים במסנן. יתר הקבצים נשארים לבדיקה אישית." : "נבחרו רק תוצרים מוכרים וישנים לבדיקה; זו אינה הוכחה שאינם בשימוש."
                }
            } catch { DispatchQueue.main.async {
                guard epoch.current(generation), selectionToken.current(selectionGeneration) else { return }
                self.filtering = false; self.storageError = error.localizedDescription
            } }
        }
    }

    func togglePage() { let ids = Set(pageFiles.filter(\.canTrash).map(\.id)); if ids.isSubset(of:selected) { selected.subtract(ids) } else { selected.formUnion(ids) } }
    func protectSelection(days:Int?) {
        let paths = Array(selected), until = days.flatMap { Calendar.current.date(byAdding:.day,value:$0,to:Date()) }
        ioQueue.async { ProtectionStore.shared.protect(paths:paths,until:until); DispatchQueue.main.async { self.selected = []; ProtectionUI.shared.revision += 1; self.rebuild() } }
    }
    func copyPaths() { let paths = Array(selected); ioQueue.async { let text = paths.sorted().joined(separator:"\n"); DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) } } }
    func openAI() {
        guard let database else { aiCandidates = files.filter(\.canTrash).map { AICandidate(id:$0.id,path:$0.path,title:$0.title,category:$0.category,bytes:$0.bytes,modified:$0.modified,temporary:$0.isTemporary,allowed:$0.canTrash,reason:$0.reason) }; ai = true; return }
        guard !preparingAI else { return }
        preparingAI = true; let generation = aiEpoch.advance(), epoch = aiEpoch
        let protected = ProtectionStore.shared.entries()
        aiQueue.async {
            do {
                var request = InventoryQuery(); request.limit = 500; request.protected = protected; request.actionableOnly = true
                var candidates:[AICandidate] = []
                try database.forEachFile(request:request,isCancelled:{ !epoch.current(generation) }) { file in
                    candidates.append(AICandidate(id:file.id,path:file.path,title:file.title,category:file.category,bytes:file.bytes,modified:file.modified,temporary:file.isTemporary,allowed:file.canTrash,reason:file.reason))
                }
                DispatchQueue.main.async { guard epoch.current(generation) else { return }; self.aiCandidates = candidates; self.preparingAI = false; self.ai = true }
            } catch { DispatchQueue.main.async { guard epoch.current(generation) else { return }; self.preparingAI = false; self.storageError = error.localizedDescription } }
        }
    }
    func cancelPreparingAI() { _ = aiEpoch.advance(); preparingAI = false }
    func loadIssues(offset:Int = 0) { guard let database else { coverage = true; return }; ioQueue.async { do { let rows = try database.issues(offset:offset,limit:500); DispatchQueue.main.async { self.issues = rows; self.issueOffset = offset; self.coverage = true } } catch { DispatchQueue.main.async { self.storageError = error.localizedDescription } } } }
    func stopCleanup() { cleanupGate.cancel(); engine.cancelCleanup() }
    func clean() {
        let paths = Array(selected); guard !paths.isEmpty else { return }
        cleaning = true; cleanupDone = 0; cleanupTotal = paths.count; cleanupPath = "בודק קבצים והגנות…"; cleanupGate.reset()
        let worker = engine, database = self.database, gate = cleanupGate, fallback = chosen
        DispatchQueue.global(qos:.utility).async {
            var successes:[String] = [], errors:[String] = []
            for lower in stride(from:0,to:paths.count,by:256) {
                if gate.stopped { errors.append("הניקוי נעצר לפני טיפול בכל הבחירה."); break }
                let chunk = Array(paths[lower..<min(lower+256,paths.count)])
                do {
                    let targets = try database?.selected(paths:chunk,limit:256).files ?? fallback.filter { chunk.contains($0.path) }
                    worker.cleanup(files:targets,progress:{ done,_,path in DispatchQueue.main.async { self.cleanupDone = lower+done; self.cleanupPath = path } }) { passed,failed in successes += passed; errors += failed }
                    if targets.count < chunk.count { errors.append("\(chunk.count-targets.count) פריטים אינם זמינים או מוגנים ולא הועברו לפח.") }
                } catch { errors.append(error.localizedDescription) }
            }
            let removed = Set(successes), allErrors = errors
            DispatchQueue.main.async {
                self.selected.subtract(removed); self.cleaning = false; self.removedCount = removed.count; self.resultErrors = allErrors; self.resultText = "\(removed.count) קבצים הועברו לפח.\n"+allErrors.joined(separator:"\n"); self.result = true
                if database != nil { self.refreshDisk() } else { self.files.removeAll { removed.contains($0.path) }; self.summarize(); self.rebuild() }
            }
        }
    }
    func rebuildMemory() {
        let protected = ProtectionStore.shared.entries()
        let cutoff = Calendar.current.date(byAdding: .day, value: -age, to: Date()) ?? Date()
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        let inventory = files, section = self.section, minimum = self.minimum, age = self.age, sort = self.sort
        filterGeneration = filterEpoch.advance()
        let generation = filterGeneration, epoch = filterEpoch
        filterQueue.cancelAllOperations()
        filtering = true
        filterQueue.addOperation {
        guard epoch.current(generation) else { return }
        var output: [DeepFile] = []
        output.reserveCapacity(inventory.count)
        for (index,file) in inventory.enumerated() {
            if index.isMultiple(of:256) && !epoch.current(generation) { return }
            if protected.contains(where: { file.path == $0.path || file.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(file.path + "/") }) { continue }
            if section == "זמניים" && !file.isTemporary { continue }
            if section == "גדולים" && file.bytes < 100 * 1024 * 1024 { continue }
            if section != "הכול" && section != "זמניים" && section != "גדולים" && file.category != section { continue }
            if file.bytes < minimum || (age > 0 && file.modified > cutoff) { continue }
            if words.allSatisfy({ (file.title + " " + file.path + " " + file.reason).localizedCaseInsensitiveContains($0) }) { output.append(file) }
        }
        var comparisons = 0
        do { try output.sort { a,b in
            comparisons += 1
            if comparisons.isMultiple(of:1024) && !epoch.current(generation) { throw FilterCancelled.cancelled }
            switch sort {
            case .largest: if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .smallest: if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .oldest: if a.modified != b.modified { return a.modified < b.modified }
            case .newest: if a.modified != b.modified { return a.modified > b.modified }
            case .name: break
            }
            if sort != .name { return a.path < b.path }
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
        } catch { return }
        guard epoch.current(generation) else { return }
        let ready = output
        DispatchQueue.main.async {
            guard generation == self.filterGeneration else { return }
            self.filtered = ready; self.page = min(self.page, self.pageCount - 1); self.filtering = false
        }
        }
        selected = selected.filter { id in !protected.contains { id == $0.path || id.hasPrefix($0.path + "/") || $0.path.hasPrefix(id + "/") } }
    }
}
final class CleanupGate: @unchecked Sendable {
    private let lock = NSLock(); private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    var stopped:Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct DashboardView: View {
    @ObservedObject var model: ExplorerModel
    @ObservedObject private var protection = ProtectionUI.shared
    @ObservedObject private var permissions = PermissionSetup.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationMotion
    @State private var showScanOptions = false
    @State private var showSummary = false
    @State private var showFilters = false
    @State private var filterGroup = "מיון"
    @State private var showSelectionActions = false
    var body: some View {
        VStack(spacing: 0) {
            compactNavigation
            if model.cloud { CloudView().frame(maxWidth: .infinity).transition(.opacity) } else {
                VStack(spacing: 0) {
                    fixedToolbar
                    ScrollView(.vertical) { fileList.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 1180).frame(maxWidth: .infinity) }
                        .frame(maxHeight: .infinity)
                    bottomBar
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AmbientBackground()).transition(.opacity)
            }
        }.preferredColorScheme(.dark).tint(Palette.accent).buttonStyle(StudioButtonStyle())
        .sheet(isPresented: $showSummary) { summarySheet }
        .sheet(isPresented: $showFilters) { filterSheet }
        .sheet(isPresented: $showSelectionActions) { selectionActionsSheet }
        .sheet(isPresented: Binding(get: { model.focus != nil }, set: { if !$0 { model.focus = nil } })) {
            if let file = model.focus {
                VStack(spacing: 12) {
                    HStack { Text("פרטי הקובץ").font(.headline); Spacer(); Button("סגור") { model.focus = nil } }.padding(.horizontal, 20).padding(.top, 16)
                    ScrollView { inspector(file) }
                    inspectorActions(file).padding(.horizontal, 20).padding(.bottom, 16)
                }.responsiveSheet(width: 680, height: 680).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
            }
        }
        .sheet(isPresented: $protection.manager) { ProtectionManager() }
        .sheet(isPresented: Binding(get: { protection.customPath != nil }, set: { if !$0 { protection.customPath = nil } })) { ProtectionDateSheet() }
        .sheet(isPresented: $model.ai,onDismiss:{model.aiCandidates = []}) { AIAssistantView(candidates:model.aiCandidates,source:.local) { model.selected = $0 } }
        .sheet(isPresented: $permissions.show) { PermissionSetupView { model.permissionsDone() } }
        .sheet(isPresented: $model.coverage) { coverageSheet }
        .sheet(isPresented: $model.confirm) { cleanupConfirmation }
        .sheet(isPresented: $model.result) { cleanupReceipt }
        .onChange(of: protection.revision) { _ in if !model.scanning { model.rebuild(); model.refreshSelection() } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.cloud)
    }
    var compactNavigation: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 32, height: 32)
                    .background(LinearGradient(colors: [Color(red: 0.34, green: 0.44, blue: 0.62), Color(red: 0.25, green: 0.35, blue: 0.48), Palette.accent.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.18)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("מקום לנשום").font(.system(size: 16, weight: .bold, design: .rounded)).tracking(0.2)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button { permissions.show = true } label: { Label("הרשאות", systemImage: "hand.raised") }
                        .help("בדיקת גישה לתיקיות והכנת הרשאות לסריקה")
                    Button { protection.manager = true } label: { Label("מוגנים", systemImage: "lock.shield") }
                        .help("הצגה וניהול של קבצים המוגנים מניקוי")
                }.buttonStyle(StudioButtonStyle()).font(.caption)

            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    navigationChip("כל הקבצים", "square.grid.2x2", "הכול")
                    navigationChip("זמניים ומטמונים", "sparkles", "זמניים")
                    navigationChip("קבצים גדולים", "chart.bar.xaxis", "גדולים")
                    Button { withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { model.cloud = true } } label: { chipLabel("iCloud Drive", "icloud", model.cloud) }.buttonStyle(.plain)
                }.padding(.vertical, 1)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 1180).frame(maxWidth: .infinity)
            .background(Color(red: 0.045, green: 0.052, blue: 0.072))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
    func navigationChip(_ title: String, _ icon: String, _ section: String) -> some View {
        Button { withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { model.cloud = false; model.section = section } } label: { chipLabel(title, icon, !model.cloud && model.section == section) }.buttonStyle(.plain)
    }
    func chipLabel(_ title: String, _ icon: String, _ active: Bool) -> some View {
        Label(title, systemImage: icon).font(.system(size: 12, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Color.white.opacity(0.96) : .white.opacity(0.57)).padding(.horizontal, 12).padding(.vertical, 7)
            .background {
                if active {
                    if reduceMotion {
                        Capsule().fill(LinearGradient(colors: [Palette.accent.opacity(0.15), Color(red: 0.42, green: 0.44, blue: 0.68).opacity(0.2)], startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(LinearGradient(colors: [Palette.accent.opacity(0.15), Color(red: 0.42, green: 0.44, blue: 0.68).opacity(0.2)], startPoint: .leading, endPoint: .trailing)).matchedGeometryEffect(id: "activeNavigation", in: navigationMotion)
                    }
                }
            }
            .overlay(Capsule().stroke(active ? Palette.accent.opacity(0.24) : Color.clear))
            .contentShape(Capsule()).fixedSize()
    }
    var fixedToolbar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                if model.scanning {
                    Button(model.paused ? "המשך" : "השהה") { model.togglePause() }
                    Button { model.engine.cancel() } label: { Label("עצור", systemImage: "stop.fill") }
                } else {
                    if model.resumeAvailable { Button { model.requestScan(resume: true) } label: { Label("המשך", systemImage: "play.fill") }.disabled(model.cleaning) }
                    Button { model.requestScan() } label: { Label(model.completed ? "סריקה מחדש" : "סריקה", systemImage: "viewfinder") }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.cleaning)
                }
                Button(action: model.chooseRoot) { Label("תיקייה", systemImage: "folder.badge.plus") }.disabled(model.busy)
                Button("סיכום והגדרות") { showSummary = true }
                Button("סינון ומיון") { showFilters = true }
                Spacer(minLength: 0)
                Button("כיסוי") { model.loadIssues() }.disabled(!model.completed && !model.scanning)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("חיפוש בשם, בנתיב או בסיווג", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                Text(model.filtering ? "מסנן…" : "\(model.matchCount.formatted()) תוצאות").font(.caption2).foregroundStyle(.secondary).fixedSize()
                Button("איפוס") { resetFilters() }
            }.padding(.horizontal, 10).padding(.vertical, 5).studioPanel(radius: 11, accented: true)
            HStack(spacing: 8) {
                Button("מועמדים") { model.selectVisible() }.disabled(model.busy || model.filtering).help("מסמן תוצרי מטמון מוכרים בני 30 יום לפחות בכל התוצאות המסוננות")
                Button("בחר עמוד") { model.togglePage() }.disabled(model.busy || model.filtering)
                Button("נקה") { model.selected = [] }.disabled(model.selected.isEmpty)
                Button { model.openAI() } label: { Label("AI", systemImage: "sparkles") }.disabled(!model.completed || model.busy || model.preparingAI)
                Button("פעולות בבחירה") { showSelectionActions = true }.disabled(model.chosenCount == 0 || model.busy)
                Spacer(minLength: 0)
                Text(activeFilterSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(activeFilterSummary)
            }
            if model.scanning || model.cleaning || model.preparingAI || model.loadingIndex {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.cleaning ? "מעביר לפח · \(model.cleanupDone)/\(model.cleanupTotal)" : model.preparingAI ? "מכין נתונים ל־AI" : model.loadingIndex ? "טוען אינדקס" : "\(model.progress.found.formatted()) קבצים · \(model.paused ? "מושהה" : "סורק")").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if model.cleaning { Button("עצור פעולות נוספות") { model.stopCleanup() } }
                    if model.preparingAI { Button("בטל הכנה") { model.cancelPreparingAI() } }
                }
            }
        }.buttonStyle(StudioButtonStyle()).font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 1180).frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Color.white.opacity(0.025), Color.white.opacity(0.008)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1) }
    }
    func resetFilters() { model.query = ""; model.minimum = 0; model.age = 0; model.section = "הכול" }
    var activeFilterSummary: String {
        let minimum = model.minimum == 0 ? "כל הגדלים" : "מעל " + size(model.minimum)
        let age = model.age == 0 ? "כל התאריכים" : "מעל \(model.age) ימים"
        return "\(model.section) · \(model.sort.rawValue) · \(minimum) · \(age)"
    }
    func filterGroupTitle(_ group: String) -> String {
        let active = group == "סוג" ? model.section != "הכול" : group == "גודל" ? model.minimum != 0 : group == "גיל" ? model.age != 0 : model.sort != .largest
        return group + (active ? " •" : "")
    }
    var filterSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("סינון ומיון").font(.title2.bold()); Spacer(); Button("סגור") { showFilters = false } }
            HStack(spacing: 8) {
                ForEach(["מיון", "סוג", "גודל", "גיל"], id: \.self) { group in
                    Button { filterGroup = group } label: {
                        Text(filterGroupTitle(group)).font(.system(size: 13, weight: filterGroup == group ? .semibold : .regular)).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(filterGroup == group ? Palette.accent : .secondary)
                            .background(filterGroup == group ? Palette.accent.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(filterGroup == group ? Palette.accent.opacity(0.4) : Color.white.opacity(0.06)))
                    }.buttonStyle(.plain).accessibilityAddTraits(filterGroup == group ? .isSelected : [])
                }
            }
            Text(activeFilterSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if filterGroup == "מיון" {
                        VisibleChoices(title: "מיון", selection: $model.sort, options: ExplorerSort.allCases.map { ($0.rawValue, $0) })
                    } else if filterGroup == "סוג" {
                        VisibleChoices(title: "סוג קובץ", selection: $model.section, options: [("כל הסוגים", "הכול")] + model.categoryStats.map { ($0.0, $0.0) })
                    } else if filterGroup == "גודל" {
                        VisibleChoices(title: "גודל מינימלי", selection: $model.minimum, options: [("כל הגדלים", Int64(0)), ("מעל 1MB", Int64(1024*1024)), ("מעל 100MB", Int64(100*1024*1024)), ("מעל 1GB", Int64(1024*1024*1024))])
                    } else {
                        VisibleChoices(title: "שינוי אחרון", selection: $model.age, options: [("כל התאריכים", 0), ("מעל שבוע", 7), ("מעל חודש", 30), ("מעל 3 חודשים", 90)])
                    }
                }.padding(.vertical, 4)
            }
            HStack { Button("אפס מסננים") { resetFilters() }; Spacer(); Text("\(model.matchCount.formatted()) תוצאות").font(.caption).foregroundStyle(.secondary); Button("הצג תוצאות") { showFilters = false } }
        }.padding(20).responsiveSheet(width: 700, height: 500).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
    }
    var selectionActionsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("פעולות בבחירה").font(.title2.bold()); Spacer(); Button("סגור") { showSelectionActions = false } }
            Text("\(model.chosenCount.formatted()) קבצים נבחרו").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                Button("הגן ללא הגבלת זמן") { model.protectSelection(days: nil); showSelectionActions = false }
                Button("הגן לשבוע") { model.protectSelection(days: 7); showSelectionActions = false }
                Button("הגן לחודש") { model.protectSelection(days: 30); showSelectionActions = false }
                Button("העתק נתיבים") { model.copyPaths() }
                Button("הצג ב־Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.chosen.map { URL(fileURLWithPath: $0.path) }) }
            }.buttonStyle(StudioButtonStyle())
        }.padding(20).responsiveSheet(width: 600).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
    }
    var summarySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("סיכום ופרטי הסריקה").font(.title2.bold()); Spacer(); Button("סגור") { showSummary = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VisibleChoices(title: "היקף הסריקה", selection: $model.scope, options: [("כל המק הנגיש", "mac"), ("קבצי המשתמש", "home")] + (model.customRoot == nil ? [] : [("תיקייה נבחרת", "custom")])).disabled(model.busy)
                    VisibleChoices(title: "משאבי הסריקה", selection: $model.performance, options: ScanPerformance.allCases.map { ($0.displayName, $0) }).disabled(model.busy)
                    overview
                    if !model.completed && !model.scanning { welcomeCard }
                    if model.scanning { ScanActivityPanel(progress: model.progress, startedAt: model.startedAt) }
                    if model.cleaning { cleanupPanel }
                    if !model.storageError.isEmpty { Text(model.storageError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if !model.selectionNotice.isEmpty { Text(model.selectionNotice).font(.caption).foregroundStyle(.secondary) }
                    if model.completed { coverageBanner }
                }
            }
        }.padding(20).responsiveSheet(width: 760, height: 650).preferredColorScheme(.dark).environment(\.layoutDirection, .rightToLeft)
    }
    var scanOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    showScanOptions.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent)
                        .frame(width: 38, height: 38)
                        .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("אפשרויות סריקה").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        Text(model.performance.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(showScanOptions ? "סגירה" : "שינוי הגדרות")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                    Image(systemName: showScanOptions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
                }
                .padding(14).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("אפשרויות סריקה")
            .accessibilityValue("\(showScanOptions ? "פתוח" : "סגור"), \(model.performance.displayName)")
            .accessibilityHint(showScanOptions ? "סגירת אפשרויות הסריקה" : "פתיחת אפשרויות הסריקה לשינוי מצב המשאבים")
            if showScanOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    Text("משאבים לסריקה").font(.subheadline.weight(.semibold))
                    ResponsiveRow(alignment: .top, spacing: 10) {
                        ForEach(ScanPerformance.allCases) { performance in
                            scanPerformanceButton(performance)
                        }
                    }
                    if model.busy {
                        Label("אפשר לשנות את המצב לאחר סיום הפעולה הנוכחית", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.scope == "mac" ? "כולל קבצים מוסתרים ותוכן חבילות שנגישים למערכת. קבצי מערכת מוצגים לעיון; אינם זמינים לניקוי." : model.roots.map(\.path).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 14).padding(.bottom, 16)
            }
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(showScanOptions ? 0.30 : 0.16)))
    }
    func scanPerformanceButton(_ performance: ScanPerformance) -> some View {
        let selected = model.performance == performance
        let icon = performance == .background ? "leaf" : performance == .balanced ? "scale.3d" : "bolt.fill"
        let detail = performance == .background ? "עובד יחיד בעדיפות נמוכה" : performance == .balanced ? "עד שני עובדים במקביל" : "כל הליבות הזמינות"
        return Button {
            model.performance = performance
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                }.font(.system(size: 16, weight: .semibold)).foregroundStyle(selected ? Palette.accent : Color.secondary)
                Text(performance == .turbo ? "טורבו" : performance.displayName)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(selected ? Palette.accent.opacity(0.12) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.accent.opacity(0.65) : Color.white.opacity(0.10), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(model.busy).opacity(model.busy ? 0.55 : 1)
        .accessibilityLabel(performance.displayName)
        .accessibilityValue(selected ? "נבחר" : "לא נבחר")
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                BreathCompanion(mode: .ready, diameter: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("מפנים מקום בשלושה צעדים").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("גלו קבצים גדולים ושאריות של אפליקציות. שום קובץ לא נבחר או נמחק מעצמו.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                welcomeStep("1", "סורקים", "את המק או תיקייה לבחירתכם")
                welcomeStep("2", "בודקים", "פותחים פרטים ומסמנים קבצים")
                welcomeStep("3", "מעבירים לפח", "רק אחרי סקירה ואישור")
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Palette.accent.opacity(0.12), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.accent.opacity(0.18)))
    }
    func welcomeStep(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
                .frame(width: 24, height: 24).background(Palette.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var overview: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                stat("כל הקבצים שנסרקו",model.scanning ? "\(model.progress.found.formatted())" : "\(model.inventoryCount.formatted())", "doc.on.doc", Palette.accent)
                stat("נפח הקבצים שנסרקו",size(model.scanning ? model.progress.bytes : model.totalBytes),"internaldrive",Color(red:0.62,green:0.70,blue:0.85))
                stat("נבחרו להעברה לפח","\(model.chosenCount.formatted()) · \(size(model.chosenBytes))","checkmark.circle",Color(red:0.72,green:0.64,blue:0.94))
            }
            Text("זהו נפח הקבצים שנמצאו, לא המקום שאפשר לפנות. רק מה שתסמנו ייכלל בסקירה לפני העברה לפח.").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            if !model.categoryStats.isEmpty {
                GeometryReader { geo in HStack(spacing: 3) { ForEach(model.categoryStats.prefix(8),id:\.0) { category,bytes in RoundedRectangle(cornerRadius:3).fill(categoryColor(category)).frame(width:max(2,geo.size.width * CGFloat(bytes) / CGFloat(max(1,model.totalBytes)) - 3)).help("\(category) · \(size(bytes))") } } }.frame(height: 7)
            }
        }
    }
    func stat(_ title:String,_ value:String,_ icon:String,_ color:Color) -> some View {
        VStack(alignment:.leading,spacing:10) { HStack(alignment: .top, spacing: 6) { Text(title).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0); Image(systemName:icon).font(.caption).foregroundStyle(color) }; Text(value).font(.system(size:20,weight:.semibold,design:.rounded)).lineLimit(1).minimumScaleFactor(0.8) }.padding(13).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.06)))
    }
    var coverageBanner: some View {
        ResponsiveRow {
            Image(systemName: model.cancelled ? "pause.circle" : "checkmark.circle.fill").foregroundStyle(model.cancelled ? .orange : Palette.accent)
            Text(model.cancelled ? "הסריקה נעצרה · התוצאות שנאספו נשמרו" : "המעבר על ההיקף הנגיש הסתיים").font(.caption)
            if let percent = model.progress.directoryPercent {
                Text("\(percent)% מהתיקיות שהתגלו").font(.caption).monospacedDigit().help("אומדן לפי תיקיות שהתגלו בהיקף שנבחר, כולל תיקיות שדולגו; אינו אחוז מכל הקבצים או נפח המחשב.")
            }
            Spacer()
            Button("דוח כיסוי · \(model.issueTotal) דילוגים") { model.loadIssues() }.font(.caption).buttonStyle(.borderless)
        }.padding(12).background(Palette.accent.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
    }
    var fileList: some View {
        VStack(spacing:0) {
            HStack { Label("קבצים ומיקומים", systemImage: "doc.on.doc"); Spacer(); Text("לחצו על קובץ לפרטים") }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal,14).padding(.vertical,12)
            Divider().opacity(0.4)
            LazyVStack(spacing: 6) { ForEach(model.pageFiles) { file in fileRow(file) } }.padding(6)
            if model.filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.scanning ? "viewfinder" : model.completed ? "magnifyingglass" : "tray")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent)
                        .frame(width: 68, height: 68).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    Text(model.loadingIndex ? "פותחים את התמונה האחרונה…" : model.scanning ? "מגלים מה נמצא במק…" : model.completed ? "לא נמצאו קבצים בתצוגה הזו" : "הקבצים שלכם יופיעו כאן")
                        .font(.headline)
                    Text(model.scanning ? "התוצאות מתעדכנות לאורך הסריקה. אפשר להשהות בכל רגע." : model.completed ? "אפשר לנסות חיפוש אחר, לשנות קטגוריה או לאפס את המסננים." : "לחצו על ״התחילו בסריקה״ למעלה. הסריקה רק מציגה קבצים.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(36)
            }
        }.background(.white.opacity(0.025),in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(.white.opacity(0.05)))
    }
    func fileRow(_ file:DeepFile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            fileSelection(file).padding(.top, 7)
            VStack(alignment: .leading, spacing: 8) {
                fileName(file)
                HStack(spacing: 8) {
                    Text(size(file.bytes)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 7).padding(.vertical, 4).background(Palette.accent.opacity(0.07), in: Capsule())
                    Label(file.modified.formatted(date:.numeric,time:.omitted), systemImage: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                    if !file.canTrash { Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.7)).help("לעיון בלבד") }
                    Spacer(minLength: 0)
                    fileActions(file)
                }.padding(.leading, 44)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12)
            .background(model.selected.contains(file.id) ? Palette.accent.opacity(0.065) : Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selected.contains(file.id) ? Palette.accent.opacity(0.24) : Color.white.opacity(0.035)))
            .studioHover(radius: 12)
    }
    func fileSelection(_ file: DeepFile) -> some View {
        Toggle("בחר \(file.title)",isOn:Binding(get:{model.selected.contains(file.id)},set:{if $0 {model.selected.insert(file.id)} else {model.selected.remove(file.id)}})).toggleStyle(AnimatedCheckStyle(title:"בחר \(file.title)")).disabled(!file.canTrash || model.busy)
    }
    func fileName(_ file: DeepFile) -> some View {
        Button { model.focus = file } label: {
            HStack(spacing: 10) {
                Image(systemName:file.cleanupAssessment.recommendationEligible ? "sparkles" : file.isTemporary ? "archivebox" : "doc.text").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(file.cleanupAssessment.recommendationEligible ? Palette.accent : Color(red: 0.67, green: 0.67, blue: 0.83))
                    .frame(width: 34, height: 36)
                    .background(file.cleanupAssessment.recommendationEligible ? Palette.accent.opacity(0.075) : Color(red: 0.43, green: 0.43, blue: 0.64).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment:.leading,spacing:5) {
                    Text(file.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.white.opacity(0.9))
                    Text((file.path as NSString).deletingLastPathComponent).font(.system(size: 10, design:.monospaced)).foregroundStyle(.white.opacity(0.35)).lineLimit(1).truncationMode(.middle).environment(\.layoutDirection,.leftToRight)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func fileActions(_ file: DeepFile) -> some View {
        Button("פעולות") { model.focus = file }.buttonStyle(StudioButtonStyle()).font(.caption)
    }
    var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(model.chosenCount == 0 ? "סמנו קבצים לבדיקה" : "\(model.chosenCount.formatted()) נבחרו · \(size(model.chosenBytes))").font(.system(size:12,weight:.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.confirm = true } label: { Label("סקירה והעברה לפח",systemImage:"trash") }.buttonStyle(StudioButtonStyle(prominent: true)).fixedSize().disabled(model.chosenCount == 0 || model.busy)
            }
            HStack {
                Button("הקודם") { model.page -= 1 }.disabled(model.page == 0)
                Spacer(minLength: 0)
                Text("עמוד \(model.page + 1) מתוך \(model.pageCount) · עד 100 קבצים").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("הבא") { model.page += 1 }.disabled(model.page + 1 >= model.pageCount)
            }.buttonStyle(StudioButtonStyle()).font(.caption)
        }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: 1180).frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Color(red:0.065,green:0.075,blue:0.11), Color(red:0.05,green:0.06,blue:0.09)], startPoint: .top, endPoint: .bottom)).overlay(alignment:.top) { Rectangle().fill(.white.opacity(0.06)).frame(height:1) }
    }
    func inspector(_ file:DeepFile) -> some View {
        let assessment = file.cleanupAssessment
        return VStack(alignment:.leading,spacing:18) {
            Image(systemName:file.isTemporary ? "archivebox.fill" : "doc.text.fill").font(.system(size:46)).foregroundStyle(Palette.accent).padding(.vertical,15)
            Text(file.title).font(.title3.bold()).textSelection(.enabled)
            Text(file.category).font(.caption).padding(7).background(Palette.accent.opacity(0.12),in:Capsule())
            Label(assessment.recommendationEligible ? "מועמד שמרני לבדיקה" : "לא נבחר אוטומטית לניקוי",systemImage:assessment.recommendationEligible ? "checkmark.shield" : "hand.raised").font(.caption)
            Text(assessment.reason).font(.subheadline).foregroundStyle(.secondary)
            Text("סיווג בסריקה: " + file.reason).font(.caption2).foregroundStyle(.secondary)
            Divider()
            detail("נפח מקומי",size(file.bytes)); detail("שינוי אחרון",file.modified.formatted(date:.abbreviated,time:.shortened))
            Text(file.path).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled).environment(\.layoutDirection,.leftToRight)
            if !file.canTrash { Label("לעיון בלבד — מערכת, חבילה או קובץ ללא הרשאת ניקוי",systemImage:"lock").font(.caption).foregroundStyle(.orange) }
            Spacer()
            Text("סיווג זמני הוא הסבר לבדיקה, לא הבטחה שהקובץ מיותר. סגור את האפליקציה הרלוונטית לפני ניקוי.").font(.caption2).foregroundStyle(.secondary)
        }.padding(20)
    }
    func inspectorActions(_ file: DeepFile) -> some View {
        HStack(spacing: 12) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) } label: { Label("פתח", systemImage: "arrow.up.forward.app") }
            Button { reveal(file) } label: { Label("Finder", systemImage: "folder") }
            Button { copy(file.path) } label: { Label("העתק נתיב", systemImage: "doc.on.doc") }
            ProtectionControl(path: file.path) { model.rebuild() }
        }.buttonStyle(StudioButtonStyle()).controlSize(.small).font(.caption)
    }
    func detail(_ title:String,_ value:String) -> some View { VStack(alignment:.leading,spacing:5) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption) } }
    var cleanupPanel: some View {
        VStack(alignment:.leading,spacing:10) { ResponsiveRow { Text("מעביר לפח · \(model.cleanupDone) מתוך \(model.cleanupTotal)").font(.headline); Spacer(); Button("עצור פעולות נוספות") { model.stopCleanup() }.buttonStyle(.borderless) }; ProgressView(value:Double(model.cleanupDone),total:Double(max(1,model.cleanupTotal))).tint(Palette.accent); Text(model.cleanupPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }.padding(16).background(Palette.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
    }
    var cleanupConfirmation: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("סקירת ההסרה",systemImage:"trash").font(.title2.bold())
            ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("\(model.chosenCount.formatted()) קבצים · \(size(model.chosenBytes)) משוערים").font(.headline).foregroundStyle(Palette.accent)
            Text("הקבצים יועברו לפח בלבד. בדיקת הרשאות, זהות והגנות תבוצע שוב. קבצים שהשתנו או נחסמו לא יועברו. סגור אפליקציות שמשתמשות בקבצים אלה.").font(.subheadline).foregroundStyle(.secondary)
            Text("תצוגה מקדימה של עד 100 קבצים; הפעולה תחול על כל הבחירה.").font(.caption2).foregroundStyle(.secondary)
            LazyVStack(alignment:.leading,spacing:9) { ForEach(model.chosen) { file in HStack { Text(file.title).lineLimit(1); Spacer(); Text(size(file.bytes)).foregroundStyle(.secondary) }.font(.caption) } }
            } }
            ResponsiveRow { Button("ביטול") { model.confirm = false }.buttonStyle(MotionButtonStyle(prominent:false)); Spacer(); Button("העבר לפח") { model.confirm = false; model.clean() }.buttonStyle(MotionButtonStyle()).disabled(model.chosenCount == 0) }
        }.padding(20).responsiveSheet(width: 580, height: 520).environment(\.layoutDirection,.rightToLeft).preferredColorScheme(.dark)
    }
    var coverageSheet: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("דוח כיסוי הסריקה",systemImage:"list.bullet.clipboard").font(.title2.bold())
            ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text(model.scannedRoots).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(model.inventoryCount.formatted()) קבצים נשמרו באינדקס. \(model.cancelled ? "הסריקה נעצרה לבקשתך." : "המעבר הסתיים.")").font(.subheadline)
            Text("הדוח מפרט הרשאות חסרות, קישורים, פריטי ענן ונתיבים שדולגו כדי להימנע מהורדות, כפילויות או מעבר לכוננים אחרים.").font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment:.leading,spacing:12) { ForEach(Array(model.issues.enumerated()),id:\.offset) { _,issue in VStack(alignment:.leading,spacing:5) { Text(issue.reason).font(.caption); Text(issue.path).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }.frame(maxWidth:.infinity,alignment:.leading) } }
            } }
            HStack { Button("הקודם") { model.loadIssues(offset:max(0,model.issueOffset-500)) }.disabled(model.issueOffset == 0); Spacer(); Text("\(model.issueOffset+1)–\(model.issueOffset+model.issues.count) מתוך \(model.issueTotal)").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("הבא") { model.loadIssues(offset:model.issueOffset+500) }.disabled(model.issueOffset+model.issues.count >= model.issueTotal) }.buttonStyle(.borderless)
            ResponsiveRow {
            Button("העתק רשומות מוצגות") { copy(model.issues.map { $0.path + " — " + $0.reason }.joined(separator:"\n")) }.buttonStyle(MotionButtonStyle(prominent:false)); Spacer(); Button("סגור") { model.coverage = false }.buttonStyle(MotionButtonStyle()) }
        }.padding(20).responsiveSheet(width: 660, height: 580).environment(\.layoutDirection,.rightToLeft).preferredColorScheme(.dark)
    }
    var cleanupReceipt: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("הפעולה הסתיימה",systemImage:"checkmark.circle.fill").font(.title2.bold()).foregroundStyle(Palette.accent)
            ScrollView { VStack(alignment: .leading, spacing: 14) {
            ResponsiveRow { BreathCompanion(mode: model.removedCount > 0 ? .relieved : .ready, diameter: 76); Text("\(model.removedCount.formatted()) הועברו לפח").font(.headline); Spacer(); Text("\(model.resultErrors.count.formatted()) לא הושלמו").foregroundStyle(.secondary) }
            Text("אפשר לשחזר דרך הפח ב־Finder. המקום יתפנה לאחר ריקונו ידנית. התוצאות עודכנו ללא סריקה חוזרת; פריטים שלא הועברו נשארו ברשימה.").font(.caption).foregroundStyle(.secondary)
            if !model.resultErrors.isEmpty {
                LazyVStack(alignment:.leading,spacing:12) { ForEach(Array(model.resultErrors.enumerated()),id:\.offset) { _,error in Text(error).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) } }
            }
            } }
            ResponsiveRow { Button("העתק פירוט") { copy(model.resultText + "\n" + model.resultErrors.joined(separator:"\n")) }.buttonStyle(MotionButtonStyle(prominent:false)); Spacer(); Button("סגור") { model.result = false }.buttonStyle(MotionButtonStyle()) }
        }.padding(20).responsiveSheet(width: 650, height: 520).environment(\.layoutDirection,.rightToLeft).preferredColorScheme(.dark)
    }
    func categoryColor(_ category:String) -> Color {
        let colors:[Color] = [Palette.accent,Color(red:0.61,green:0.55,blue:0.77),Color(red:0.40,green:0.62,blue:0.66),Color(red:0.67,green:0.61,blue:0.48),Color(red:0.47,green:0.55,blue:0.65)]
        let value = category.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % colors.count }; return colors[value]
    }
    func reveal(_ file:DeepFile) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:file.path)]) }
    func copy(_ text:String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
}
