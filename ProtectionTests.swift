import Foundation
@main struct ProtectionTests {
    static func main() {
        let suite = "StoragePilot.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProtectionStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.protect("/tmp/keep/file")
        precondition(store.isProtected("/tmp/keep/file", now: now))
        precondition(store.isProtected("/tmp/keep", now: now))
        precondition(store.isProtected("/tmp/keep/file/child", now: now))
        precondition(!store.isProtected("/tmp/keep/files", now: now))
        precondition(!store.isProtected("/tmp/keep-other", now: now))
        precondition(ProtectionStore(defaults: defaults).isProtected("/tmp/keep", now: now))
        precondition(store.ruleLabel("/tmp/keep", now: now) == "מוגן תמיד")
        store.unprotect("/tmp/keep/file")
        precondition(!store.isProtected("/tmp/keep/file", now: now))
        store.protect("/tmp/timed", until: now.addingTimeInterval(60))
        precondition(store.isProtected("/tmp/timed/child", now: now))
        precondition(store.entries(now: now).contains { $0.path == "/tmp/timed" && $0.until == now.addingTimeInterval(60) })
        precondition(!store.entries(now: now.addingTimeInterval(60)).contains { $0.path == "/tmp/timed" })
        precondition(store.ruleLabel("/tmp/timed", now: now) != nil)
        precondition(!store.isProtected("/tmp/timed", now: now.addingTimeInterval(60)))
        precondition(store.ruleLabel("/tmp/timed", now: now.addingTimeInterval(60)) == nil)
        // Cached snapshots stay stable until a mutation or an expiration boundary.
        let cachedVersion = store.revision(now: now)
        precondition(store.revision(now: now.addingTimeInterval(1)) == cachedVersion)
        let expiredVersion = store.revision(now: now.addingTimeInterval(60))
        precondition(expiredVersion != cachedVersion)
        precondition(store.revision(now: now.addingTimeInterval(61)) == expiredVersion)
        // A backwards clock/test date must restore a still-valid timed rule.
        precondition(store.isProtected("/tmp/timed", now: now))
        store.protect("/tmp/cache-change")
        precondition(store.revision(now: now) != expiredVersion)
        precondition(store.isProtected("/tmp/cache-change", now: now))
        store.unprotect("/tmp/cache-change")
        precondition(!store.isProtected("/tmp/cache-change", now: now))
        store.protect("/tmp/normalize/../normalized")
        precondition(store.isProtected("/tmp/normalized", now: now))
        store.protect("/")
        precondition(store.isProtected("/any/path", now: now))
        store.unprotect("/")
        precondition(!store.isProtected("/any/path", now: now))

        // Action guards run before any filesystem action, even for forged items.
        let path = "/private/tmp/protected-fixture-" + UUID().uuidString
        ProtectionStore.shared.protect(path)
        defer { ProtectionStore.shared.unprotect(path) }
        let item = ScanItem(id: path, path: path, title: "fixture", category: "test", bytes: 1, risk: .review)
        var rejected = false
        StorageEngine().trash([item]) { rejected = $0.count == 1 && $0[0].contains("מוגן") }
        precondition(rejected)
        let cloud = CloudItem(id: path, path: path, title: "fixture", logicalBytes: 1, localBytes: 1, canEvict: true)
        for evict in [true, false] {
            rejected = false
            CloudEngine().act(items: [cloud], evict: evict) { rejected = $0.count == 1 && $0[0].contains("מוגן") }
            precondition(rejected)
        }
        print("PASS: persistence, expiration, ancestor/descendant protection, path boundaries, normalization, root rules, local/cloud action rejection")
    }
}
