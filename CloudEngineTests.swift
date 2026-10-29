import Foundation

@main struct CloudEngineTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("cloud-deep-test-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let hidden = fixture.appendingPathComponent(".hidden")
        let package = fixture.appendingPathComponent("Sample.app/Contents/Resources")
        try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data([1]).write(to: hidden.appendingPathComponent("hidden-file"))
        try Data([2]).write(to: package.appendingPathComponent("inside-package"))
        let ordinary = fixture.appendingPathComponent("ordinary")
        try fm.createDirectory(at: ordinary, withIntermediateDirectories: true)
        for i in 0..<1000 { try Data([UInt8(i % 255)]).write(to: ordinary.appendingPathComponent("file-\(i)")) }
        try fm.createSymbolicLink(at: fixture.appendingPathComponent("symlink"), withDestinationURL: ordinary)
        let engine = CloudEngine(root: fixture)
        var updates: [ScanProgress] = []
        let report = engine.scan { updates.append($0) }
        precondition(report.items.count == 1002, "Files without iCloud metadata must remain visible in inventory")
        precondition(report.items.allSatisfy { !$0.canDelete && !$0.canEvict }, "Unconfirmed files are read-only")
        precondition(!report.limited && !report.cancelled)
        precondition(report.skipped == report.issues.count)
        precondition(report.issues.contains { $0.path.hasSuffix(".hidden/hidden-file") })
        precondition(report.issues.contains { $0.path.hasSuffix("Sample.app/Contents/Resources/inside-package") })
        precondition(report.issues.contains { $0.path.hasSuffix("symlink") && $0.reason.contains("סימבולי") })
        precondition(report.issues.filter { $0.reason.contains("אין מטא־נתונים") }.count == 1002)
        precondition(updates.last?.directoryPercent == 100 && (updates.last?.discoveredDirectories ?? 0) >= 4)
        precondition(updates.count >= 2 && updates.last!.inspected >= 1000)
        let fake = CloudItem(id: ordinary.path, path: ordinary.path, title: "fake", logicalBytes: 1,
                             localBytes: 1, canEvict: true, canDelete: true)
        for localOnly in [true, false] {
            var rejected = false
            engine.act(items: [fake], evict: localOnly) { rejected = !$0.isEmpty }
            precondition(rejected)
        }
        // A forged UI flag cannot upgrade a read-only inventory snapshot.
        if let visible = report.items.first {
            let forged = CloudItem(id: visible.id, path: visible.path, title: visible.title,
                                   logicalBytes: visible.logicalBytes, localBytes: visible.localBytes,
                                   canEvict: true, canDelete: true, modified: visible.modified)
            for evict in [true, false] {
                var rejected = false
                engine.act(items: [forged], evict: evict) { rejected = !$0.isEmpty }
                precondition(rejected && fm.fileExists(atPath: visible.path))
            }
        }
        let excluded = CloudEngine(root: fixture).scan(excludingPaths: [ordinary.path])
        precondition(excluded.items.count == 2 && !excluded.items.contains { $0.path.hasPrefix(ordinary.path + "/") })
        precondition(excluded.issues.contains { URL(fileURLWithPath: $0.path).standardizedFileURL.path == ordinary.standardizedFileURL.path && $0.reason.contains("הרשאות") })
        let excludedRoot = CloudEngine(root: fixture).scan(excludingPaths: [fixture.path])
        precondition(excludedRoot.items.isEmpty && excludedRoot.issues.count == 1)
        // Model the default Mobile Documents layout: both Drive and app data appear.
        let containers = fixture.appendingPathComponent("Mobile Documents")
        for relative in ["com~apple~CloudDocs/Documents/note.txt", "iCloud~example~Editor/Documents/draft.txt"] {
            let target = containers.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([3]).write(to: target)
        }
        let allContainers = CloudEngine(root: containers).scan()
        precondition(allContainers.items.count == 2 && allContainers.items.allSatisfy { !$0.canDelete && !$0.canEvict })
        let deniedDrive = CloudEngine(root: containers).scan(excludingPaths: [containers.appendingPathComponent("com~apple~CloudDocs").path])
        precondition(deniedDrive.items.count == 1 && deniedDrive.items[0].path.contains("iCloud~example~Editor"))
        let cancelling = CloudEngine(root: fixture)
        let cancelled = cancelling.scan { _ in cancelling.cancel() }
        precondition(cancelled.cancelled)
        precondition(cancelled.issues.contains { $0.reason.contains("נעצרה") })
        let missing = CloudEngine(root: fixture.appendingPathComponent("does-not-exist")).scan()
        precondition(missing.skipped == 1 && !missing.issues.isEmpty)
        print("PASS: uncapped iCloud metadata traversal, hidden/package descendants, explicit non-cloud/link/access issues, live progress, cancellation, forged action rejection; no actual cloud changes")
    }
}
