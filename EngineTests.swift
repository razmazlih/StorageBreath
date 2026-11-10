import Foundation
@main struct EngineTests {
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("storage-engine-test-" + UUID().uuidString)
  defer { try? fm.removeItem(at: root) }
  let derived = root.appendingPathComponent("Library/Developer/Xcode/DerivedData/TestBuild")
  try fm.createDirectory(at: derived, withIntermediateDirectories: true)
  try Data(repeating: 1, count: 6 * 1024 * 1024).write(to: derived.appendingPathComponent("binary"))
  let downloads = root.appendingPathComponent("Downloads")
  try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
  try fm.createSymbolicLink(at: downloads.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
  let tiny = root.appendingPathComponent("Library/Developer/Xcode/DerivedData/TinyBuild")
  try fm.createDirectory(at: tiny, withIntermediateDirectories: true)
  try Data([1, 2, 3]).write(to: tiny.appendingPathComponent("tiny"))
  let incomplete = root.appendingPathComponent("Library/Developer/Xcode/DerivedData/ContainsLink")
  try fm.createDirectory(at: incomplete, withIntermediateDirectories: true)
  try Data(repeating: 1, count: 6 * 1024 * 1024).write(to: incomplete.appendingPathComponent("binary"))
  try fm.createSymbolicLink(at: incomplete.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
  let engine = StorageEngine()
  let report = engine.scan(home: root)
  precondition(report.items.count == 1)
  precondition(report.items[0].risk == .safe)
  precondition(report.items[0].bytes >= 6 * 1024 * 1024)
  let fake = ScanItem(id: "/private/tmp", path: "/private/tmp", title: "fake", category: "fake", bytes: 1, risk: .safe)
  var rejected = false
  engine.trash([fake]) { errors in rejected = !errors.isEmpty }
  precondition(rejected)
  // A replacement directory with the same mtime is a different cleanup target.
  // Keep the original inode alive at another path so the filesystem cannot reuse it.
  let originalDate = try derived.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
  try fm.moveItem(at: derived, to: derived.deletingLastPathComponent().appendingPathComponent("OriginalBuild"))
  try fm.createDirectory(at: derived, withIntermediateDirectories: true)
  try Data([9]).write(to: derived.appendingPathComponent("important-new-file"))
  try fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: derived.path)
  rejected = false
  engine.trash(report.items) { errors in rejected = errors.count == 1 && errors[0].contains("השתנה") }
  precondition(rejected)
  precondition(fm.fileExists(atPath: derived.appendingPathComponent("important-new-file").path))
  print("PASS: allocated bytes, minimum threshold, DerivedData classification, symlink exclusion, incomplete directory omission, unscanned path rejection, same-mtime replacement rejection")
 }
}
