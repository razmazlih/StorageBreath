import Foundation
@main struct AIFlowResponsivenessTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-ai-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage = root.appendingPathComponent("session.json")
        let candidate = AICandidate(id:"test",path:"/private/tmp/fixture/__pycache__/test.pyc",title:"test.pyc",category:"מטמוני פיתוח",bytes:512,modified:Date().addingTimeInterval(-100*86400),temporary:true,allowed:true,reason:"test")
        let model = AIFlowModel(candidates:[candidate],source:.local,storageURL:storage)
        func settle() async throws { for _ in 0..<500 { if !model.working { return }; try await Task.sleep(nanoseconds:10_000_000) }; fatalError("background work timed out") }
        try await settle()
        model.prepare(andCopy:false)
        try await settle()
        guard let session = model.session, let group = session.groups.first else { fatalError("session not prepared: \(model.error)") }
        model.response = "{\"schema_version\":1,\"export_id\":\"\(session.exportID)\",\"recommendations\":[{\"group_id\":\"\(group.id)\",\"action\":\"select\",\"confidence\":0.95,\"reason\":\"reviewed\"}]}"
        model.validate(); try await settle()
        precondition(model.error.isEmpty, model.error)
        precondition(model.eligibleCount == 1)
        var applied = Set<String>()
        model.apply { applied = $0 }; try await settle()
        precondition(applied == ["test"])
        model.validate(); model.cancel()
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!model.working)
        let cancelledRestore = AIFlowModel(candidates:[candidate],source:.local,storageURL:storage)
        cancelledRestore.cancel()
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(cancelledRestore.session == nil && !cancelledRestore.working)
        let restored = AIFlowModel(candidates:[candidate],source:.local,storageURL:storage)
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(restored.session?.exportID == session.exportID)
        print("AI flow background prepare, validation, apply, cancellation and restore passed")
    }
}
