import Foundation

@main struct CloudSuggestionTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ name: String, age: TimeInterval = 200 * 86400, canDelete: Bool = true, canEvict: Bool = false, local: Int64 = 0) -> CloudItem {
            CloudItem(id: name, path: "/fixture/iCloud/" + name, title: name,
                      logicalBytes: 1024, localBytes: local, canEvict: canEvict,
                      canDelete: canDelete, modified: now.addingTimeInterval(-age))
        }
        let partial = CloudSuggestion.evaluate(item("video.CRDOWNLOAD", age: 60), now: now)
        precondition(partial.isCandidateForCloudDeletion && partial.isCandidate && partial.uncertainty.contains("אינה מוכיחה"))
        precondition(partial.question.contains("מכשירים"))
        let archive = CloudSuggestion.evaluate(item("backup.zip"), now: now)
        precondition(archive.isCandidateForCloudDeletion && archive.isCandidate && archive.uncertainty.contains("גיבוי יחיד"))
        precondition(!CloudSuggestion.evaluate(item("new.zip", age: 1), now: now).isCandidate)
        precondition(!CloudSuggestion.evaluate(item("old.pdf"), now: now).isCandidate,
                     "Personal documents must not become garbage merely because they are old")
        precondition(!CloudSuggestion.evaluate(item("weights.bin"), now: now).isCandidate)
        let localCopy = CloudSuggestion.evaluate(item("old.pdf", canEvict: true, local: 1024), now: now)
        precondition(!localCopy.isCandidateForCloudDeletion && localCopy.isCandidate && localCopy.uncertainty.contains("אינה מפנה מכסת iCloud"))
        precondition(localCopy.question.contains("ללא אינטרנט"))
        precondition(!CloudSuggestion.evaluate(item("inside.tmp", canDelete: false, canEvict: true, local: 1024), now: now).isCandidate)
        precondition(!CloudSuggestion.evaluate(item("unknown.zip", age: now.timeIntervalSince(.distantPast)), now: now).isCandidate)
        precondition(!CloudSuggestion.evaluate(item("future.zip", age: -86400), now: now).isCandidate)
        let noLocal = CloudSuggestion.evaluate(item("old.pdf", canEvict: true), now: now)
        precondition(!noLocal.isCandidate)
        for sample in [partial, archive, localCopy, noLocal] {
            precondition(!sample.title.isEmpty && !sample.reason.isEmpty && !sample.uncertainty.isEmpty && !sample.question.isEmpty)
        }
        print("PASS: conservative iCloud metadata suggestions, explicit uncertainty/questions, archive recency, package action denial, no automatic selection or cloud mutation")
    }
}
