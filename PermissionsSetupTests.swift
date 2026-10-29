import Foundation

@main struct PermissionsSetupTests {
    @MainActor static func main() async throws {
        let base = "/Users/permission-fixture"
        let roots = [
            PermissionRoot(label: "Documents", path: base + "/Documents"),
            PermissionRoot(label: "Downloads", path: base + "/Downloads"),
            PermissionRoot(label: "Mail", path: base + "/Library/Mail", fullDiskAccessProbe: true),
            PermissionRoot(label: "Pictures", path: base + "/Pictures")
        ]
        let unchecked = roots.map { PermissionPathStatus(path: $0.path, label: $0.label, state: .unchecked, fullDiskAccessProbe: $0.fullDiskAccessProbe) }
        let initial = PermissionPlanner.make(statuses: unchecked, prepared: false)
        precondition(!initial.prepared && initial.excluded.count == 4 && initial.fullDiskAccessHint == nil)
        let suite = "StorageStudio.PermissionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = PermissionSetup(defaults: defaults, roots: roots, probe: { url in
            switch url.lastPathComponent {
            case "Documents": return .granted
            case "Downloads": return .missing
            default: return .denied
            }
        })
        precondition(!setup.prepared && setup.statuses.allSatisfy { $0.state == .unchecked })
        setup.preflight()
        precondition(setup.checking && !setup.prepared)
        for _ in 0..<200 where setup.checking { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!setup.checking && setup.prepared && setup.checkedAt != nil)
        precondition(setup.currentPlan.excluded.count == 3)
        precondition(!setup.excludedPaths.contains(base + "/Documents"))
        precondition(setup.currentPlan.fullDiskAccessHint == false)
        precondition(setup.statuses.allSatisfy { $0.checkedAt != nil })
        let restored = PermissionSetup(defaults: defaults, roots: roots, probe: { _ in
            preconditionFailure("Restoring settings must never probe any real directory")
        })
        precondition(restored.prepared && restored.checkedAt != nil)
        precondition(restored.statuses.map(\.state) == setup.statuses.map(\.state))
        var related = [
            PermissionPathStatus(path: base + "/Documents", label: "parent", state: .unchecked),
            PermissionPathStatus(path: base + "/Documents/Chosen", label: "selected child", state: .granted),
            PermissionPathStatus(path: base + "/Documents/Denied", label: "denied child", state: .denied),
            PermissionPathStatus(path: base + "/Documents-other", label: "boundary", state: .denied)
        ]
        let childPlan = PermissionPlanner.make(statuses: related, prepared: true)
        precondition(childPlan.excluded.map(\.path).sorted() == [base + "/Documents", base + "/Documents-other"].sorted())
        related.append(PermissionPathStatus(path: "/", label: "root", state: .denied))
        precondition(PermissionPlanner.make(statuses: related, prepared: true).excluded.map(\.path) == ["/"])
        let basicGranted = [PermissionPathStatus(path: base + "/Documents", label: "Documents", state: .granted)]
        precondition(PermissionPlanner.make(statuses: basicGranted, prepared: true).fullDiskAccessHint == nil)
        let protectedGranted = [PermissionPathStatus(path: base + "/Library/Mail", label: "Mail", state: .granted, fullDiskAccessProbe: true)]
        precondition(PermissionPlanner.make(statuses: protectedGranted, prepared: true).fullDiskAccessHint == true)
        let added = PermissionSetup(defaults: defaults, roots: roots + [PermissionRoot(label: "New", path: base + "/NewGuarded")], probe: { _ in .denied })
        precondition(added.excludedPaths.contains(base + "/NewGuarded"))
        print("PASS: upfront injected permission checks, conservative unknown/denied/missing exclusions, persistence without probing, selected-child boundaries, new guarded roots, protected-directory hint only; no real TCC access or settings changes")
    }
}
