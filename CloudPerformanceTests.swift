import Foundation
@main struct CloudPerformanceTests {
    @MainActor static func main() async throws {
        let model = CloudModel()
        model.scanned = true
        let prefix = "/private/tmp/cloud-performance-" + UUID().uuidString
        model.items = (0..<20_000).map { index in
            let path = prefix + "/" + String(index)
            return CloudItem(id: path, path: path, title: String(index), logicalBytes: Int64(index + 10), localBytes: Int64(index + 1), canEvict: true)
        }
        func settle() async throws {
            for _ in 0..<500 {
                if !model.selectionUpdating { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("selection failed to settle")
        }
        model.selected = Set(model.items.map(\.id))
        model.selected = [model.items[1].id]
        try await settle()
        precondition(model.chosen.count == 1 && model.amount == 2)
        model.evict = false
        try await settle()
        precondition(model.amount == 11)
        let protectedPath = model.items[1].path
        ProtectionStore.shared.protect(protectedPath)
        defer { ProtectionStore.shared.unprotect(protectedPath) }
        model.protectionsChanged()
        try await settle()
        precondition(model.chosen.isEmpty && model.amount == 0)
        model.openAI()
        for _ in 0..<500 where model.preparingAI { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.ai && model.aiCandidates.count == 19_999 && model.aiSource == .cloudDelete)
        model.ai = false
        model.openAI(); model.cancelAI()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!model.ai && !model.preparingAI)
        model.openAI(); model.evict = true
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!model.ai && !model.preparingAI)
        model.selected = []
        precondition(!model.selectionUpdating && model.chosen.isEmpty)
        model.sort = .name
        model.search = "missing"; model.rebuild()
        model.search = "19999"; model.rebuild()
        for _ in 0..<500 {
            if model.visible.count == 1 && model.visible.first?.title == "19999" { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        precondition(model.visible.count == 1 && model.visible.first?.title == "19999")
        let searchItem = CloudItem(id: prefix + "/folder/שלום-עולם.pdf", path: prefix + "/folder/שלום-עולם.pdf", title: "שלום-עולם.pdf", logicalBytes: 1, localBytes: 0, canEvict: false, canDelete: false)
        model.items = [searchItem]
        model.search = "  עולם  folder  "; model.rebuild()
        for _ in 0..<500 {
            if model.visible.first?.id == searchItem.id { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(model.visible.count == 1 && model.visible.first?.id == searchItem.id, "Search tokens must match across name/path without requiring a phrase")
        // Selection IDs from an old AI session must not make read-only files actionable.
        model.selected = [searchItem.id]
        try await settle()
        precondition(model.chosen.isEmpty && model.amount == 0, "Read-only cloud items cannot enter an action selection")
        model.openAI()
        model.items = []
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!model.ai && !model.preparingAI, "Inventory replacement invalidates pending AI preparation")
        precondition(model.visible.isEmpty, "A previous filter must not restore an obsolete inventory")
        model.busy = true
        model.scan()
        precondition(model.busy && !model.scanning, "An operation in progress must reject overlapping scans")
        print("PASS: cloud selection latest generation, eligibility, amount modes, protection refresh, cancellable sorting, stale inventory/AI invalidation, overlapping scan rejection")
    }
}
