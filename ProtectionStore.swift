import Foundation

struct ProtectionEntry: Identifiable {
    let path: String
    let until: Date?
    var id: String { path }
}

/// Local cleanup exclusions. Protecting a child also prevents moving its parent.
final class ProtectionStore {
    static let shared = ProtectionStore()
    private struct Rule: Codable {
        let path: String
        let until: Date?
    }
    private let lock = NSRecursiveLock()
    private let defaults: UserDefaults
    private let key = "StoragePilot.protectedPaths.v1"
    private var cachedRules: [Rule]?
    private var cachedEntries: [ProtectionEntry] = []
    private var nextExpiry: Date?
    private var lastReadDate = Date.distantPast
    private var version: UInt64 = 0
    private var observer: NSObjectProtocol?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.cachedRules = nil
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func activeEntries(now: Date) -> [ProtectionEntry] {
        let rules = read()
        if lastReadDate == .distantPast || now < lastReadDate || nextExpiry.map({ now >= $0 }) == true {
            let active = rules.filter { $0.until == nil || $0.until! > now }
            cachedEntries = active.map { ProtectionEntry(path: $0.path, until: $0.until) }.sorted { $0.path < $1.path }
            nextExpiry = active.compactMap(\.until).min()
            version &+= 1
        }
        lastReadDate = now
        return cachedEntries
    }
    /// Cheap change token, including expiration; suitable for UI polling.
    func revision(now: Date = Date()) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        _ = activeEntries(now: now)
        return version
    }
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
    private func read() -> [Rule] {
        if let cachedRules { return cachedRules }
        let rules = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
        cachedRules = rules
        lastReadDate = .distantPast
        return rules
    }
    private func write(_ rules: [Rule]) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: key)
            cachedRules = rules
            lastReadDate = .distantPast
        }
    }
    private func related(_ a: String, _ b: String) -> Bool {
        a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    func entries(now: Date = Date()) -> [ProtectionEntry] {
        lock.lock(); defer { lock.unlock() }
        return activeEntries(now: now)
    }
    func isProtected(_ path: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let normalized = canonical(path)
        return activeEntries(now: now).contains { related($0.path, normalized) }
    }
    func ruleLabel(_ path: String, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        let normalized = canonical(path)
        let matches = activeEntries(now: now).filter { related($0.path, normalized) }
        guard !matches.isEmpty else { return nil }
        if matches.contains(where: { $0.until == nil }) { return "מוגן תמיד" }
        guard let until = matches.compactMap(\.until).max() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "he_IL")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "מוגן עד \(formatter.string(from: until))"
    }
    func protect(_ path: String, until: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let normalized = canonical(path)
        var rules = read().filter { $0.path != normalized }
        rules.append(Rule(path: normalized, until: until))
        write(rules)
    }
    func protect(paths:[String],until:Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let selected = Set(paths.map(canonical))
        var rules = read().filter { !selected.contains($0.path) }
        rules += selected.map { Rule(path:$0,until:until) }; write(rules)
    }
    /// Removes only the exact rule. A related parent or child rule remains effective.
    func unprotect(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let normalized = canonical(path)
        write(read().filter { $0.path != normalized })
    }
}
