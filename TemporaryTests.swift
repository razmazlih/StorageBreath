import Foundation
@main struct TemporaryTests {
 static func main() throws {
  let fm = FileManager.default
  let home = fm.temporaryDirectory.appendingPathComponent("temp-engine-fixture-" + UUID().uuidString)
  defer { try? fm.removeItem(at: home) }
  let temp = home.appendingPathComponent("private-temp")
  try fm.createDirectory(at: temp, withIntermediateDirectories: true)
  let old = temp.appendingPathComponent("old-file")
  let fresh = temp.appendingPathComponent("fresh-file")
  try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: old)
  try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: fresh)
  let date = Date().addingTimeInterval(-9 * 86400)
  try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: old.path)
  var values = URLResourceValues(); values.contentAccessDate = date
  var mutableOld = old; try mutableOld.setResourceValues(values)
  let engine = StorageEngine(temporaryRoot: temp)
  var stages: Set<String> = []
  let report = engine.scan(home: home, details: { stages.insert($0.stage) })
  precondition(report.items.contains { $0.path == old.path && $0.category == "קבצים זמניים ישנים" })
  precondition(!report.items.contains { $0.path == fresh.path })
  precondition(stages.contains("קבצים זמניים ישנים"))
  // A newly modified temporary file must be rejected after an otherwise valid scan.
  try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: old.path)
  var rejected = false
  engine.trash(report.items) { rejected = !$0.isEmpty }
  precondition(rejected)
  print("PASS: old temp eligible; fresh temp excluded; changed temp rejected; live stage progress")
 }
}
