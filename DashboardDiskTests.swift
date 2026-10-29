import Foundation

@main struct DashboardDiskTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-ui-disk-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let database = try InventoryDatabase(url:root.appendingPathComponent("index.sqlite"))
        for batch in 0..<100 {
            var entries:[(DeepFile,InventorySnapshot?)] = []
            for i in 0..<1000 {
                let number = batch*1000+i, path = "/private/tmp/fixture/file-\(number).tmp"
                let date = Date(timeIntervalSinceReferenceDate:Double(number))
                let file = DeepFile(id:path,path:path,title:"file-\(number).tmp",category:"קבצים זמניים",bytes:Int64(number),modified:date,isTemporary:true,reason:"fixture",canTrash:true)
                entries.append((file,InventorySnapshot(identity:"id-\(number)",modified:date,logicalSize:number,allowed:true,root:URL(fileURLWithPath:"/private/tmp/fixture"))))
            }
            try database.insertBatch(entries)
        }
        let model = ExplorerModel(database:database)
        func wait(_ condition:@escaping()->Bool) async throws {
            for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds:30_000_000) }
            preconditionFailure("Timed out")
        }
        try await wait { model.inventoryCount == 100000 && !model.filtering && model.filtered.count == 100 }
        precondition(model.files.isEmpty && model.pageFiles.count == 100 && model.matchCount == 100000)
        model.page = 999
        try await wait { !model.filtering && model.page == 999 && model.pageFiles.first?.title == "file-99.tmp" }
        precondition(model.files.isEmpty && model.filtered.count == 100)
        model.query = "file-99999.tmp"; model.page = 0; model.rebuild()
        try await wait { !model.filtering && model.matchCount == 1 }
        model.selectVisible()
        try await wait { !model.filtering }
        precondition(model.selected.isEmpty, "A .tmp extension must not authorize bulk cleanup")
        model.togglePage()
        try await wait { model.chosenCount == 1 && model.chosen.count == 1 }
        precondition(model.chosenBytes == 99999 && model.chosen[0].title == "file-99999.tmp")
        precondition(model.performance == .background)
        let reopened = ExplorerModel(database:try InventoryDatabase(url:database.url))
        try await wait { reopened.inventoryCount == 100000 && !reopened.filtering }
        precondition(reopened.files.isEmpty && reopened.filtered.count <= 100)
        print("PASS: 100000-row persistent inventory, only100 UI rows, lastpage/search/selection, reopen, quietdefault; no file deletion")
    }
}
