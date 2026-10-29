import Foundation

@main struct DashboardTests {
    @MainActor static func main() async throws {
        let model = ExplorerModel(inMemory:true)
        let base = "/private/tmp/explorer-ui-test-" + UUID().uuidString
        func item(_ name:String,_ bytes:Int64,_ temporary:Bool = false,_ permitted:Bool = true) -> DeepFile {
            DeepFile(id:base+"/"+name,path:base+"/"+name,title:name,category:temporary ? "קבצים זמניים" : "מסמכים",bytes:bytes,modified:Date(timeIntervalSince1970:1000+Double(bytes)),isTemporary:temporary,reason:temporary ? "cache candidate" : "personal document",canTrash:permitted)
        }
        model.files = [item("alpha.txt",30),item("beta.tmp",100,true),item("readonly.txt",200,false,false)]
        model.summarize(); model.rebuild()
        func settle() async throws {
            try await Task.sleep(nanoseconds:350_000_000)
            for _ in 0..<100 where model.filtering { try await Task.sleep(nanoseconds:20_000_000) }
            precondition(!model.filtering)
        }
        try await settle()
        precondition(model.selected.isEmpty, "Scanning and browsing must never select files")
        precondition(model.filtered.map(\.title) == ["readonly.txt","beta.tmp","alpha.txt"])
        model.selectVisible(); precondition(model.selected.isEmpty)
        model.togglePage(); precondition(model.selected.count == 2 && model.chosenBytes == 130)
        model.selected = []; model.query = "  beta cache  "; model.rebuild(); try await settle()
        precondition(model.filtered.count == 1 && model.filtered[0].title == "beta.tmp")
        model.query = ""; model.section = "זמניים"; try await settle()
        precondition(model.filtered.count == 1 && model.filtered[0].isTemporary)
        model.section = "הכול"; model.sort = .oldest; try await settle()
        precondition(model.filtered.first?.title == "alpha.txt")
        let protected = base + "/beta.tmp"
        ProtectionStore.shared.protect(protected)
        defer { ProtectionStore.shared.unprotect(protected) }
        model.query = "beta"; model.rebuild(); try await settle()
        precondition(model.filtered.isEmpty)
        ProtectionStore.shared.unprotect(protected)
        model.rebuild(); try await settle(); precondition(model.filtered.count == 1)
        model.query = ""; model.minimum = 150; try await settle()
        precondition(model.filtered.count == 1 && model.filtered[0].title == "readonly.txt")
        model.selectVisible(); precondition(model.selected.isEmpty)
        model.minimum = 0
        model.files = (0..<225).map { item("__pycache__/file-\($0).pyc",Int64($0),true) }
        model.summarize(); model.rebuild(); try await settle()
        precondition(model.pageCount == 3 && model.pageFiles.count == 100)
        model.page = 2; precondition(model.pageFiles.count == 25)
        model.selectVisible(); precondition(model.selected.count == 225)
        let candidates = model.files.map { AICandidate(id:$0.id,path:$0.path,title:$0.title,category:$0.category,bytes:$0.bytes,modified:$0.modified,temporary:$0.isTemporary,allowed:$0.canTrash,reason:$0.reason) }
        let session = try AIExportSession.create(candidates:candidates,source:.local)
        let reply: [String:Any] = ["schema_version":1,"export_id":session.exportID,"recommendations":session.groups.map { ["group_id":$0.id,"action":"select","confidence":0.95,"reason":"בדיקת ממשק בלבד"] as [String:Any] }]
        let json = String(data:try JSONSerialization.data(withJSONObject:reply),encoding:.utf8)!
        let checked = try session.review(response:json,current:candidates,protected:{ _ in false })
        model.selected = Set(checked.eligibleIDs)
        precondition(model.selected.count == 225 && !model.cleaning)
        model.selected = []
        model.files = (0..<20000).map { item("large-file-\($0)",0) }
        model.summarize(); model.sort = .name; model.rebuild()
        model.query = "missing"; model.rebuild()
        model.query = "large-file-19999"; model.rebuild()
        try await settle()
        precondition(model.filtered.count == 1 && model.filtered[0].title == "large-file-19999")
        print("PASS: AI import selects without cleanup; cancelled stale filtering over 20000 rows")
        print("PASS: search tokens, sort, temporary filter, protected hidden/restore, size filter, non-cleanable exclusions, conservative bulk candidates, explicit manual page selection and pagination")
    }
}
