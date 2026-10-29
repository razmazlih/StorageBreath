import Foundation

@main struct AIExchangeTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let now = Date()
        let secret = "sensitive-person-name"
        func candidate(_ name: String, allowed: Bool = true, bytes: Int64 = 50, modified: Date? = nil) -> AICandidate {
            let path = "/Users/\(secret)/Projects/private-app/__pycache__/\(name)"
            return AICandidate(id: path, path: path, title: name, category: "מטמוני פיתוח", bytes: bytes,
                               modified: modified ?? now.addingTimeInterval(-100 * 86_400), temporary: true, allowed: allowed, reason: "private reason \(secret)")
        }
        let first = candidate("private-first.pyc"), second = candidate("private-second.pyc")
        let session = try AIExportSession.create(candidates: [first, second], source: .local, now: now)
        precondition(session.groups.count == 1)
        let payload = try session.payload()
        precondition(!payload.contains(secret) && !payload.contains(first.title) && !payload.contains(first.path) && !payload.contains("private-app"))
        precondition(payload.contains("file_count") && payload.contains("90+ days"))
        precondition(!session.prompt().contains(secret) && session.prompt().contains(session.exportID))
        let restored = try JSONDecoder().decode(AIExportSession.self, from: JSONEncoder().encode(session))
        precondition(restored.exportID == session.exportID && restored.groups[0].members[0].path == first.path)
        let privateSession = try AIExportSession.create(candidates: [first], source: .local, includePrivatePaths: true, now: now)
        check(try privateSession.payload().contains(first.path))
        let cloud = try AIExportSession.create(candidates: [first], source: .cloudEvict, now: now)
        precondition(cloud.groups[0].location == "cloud")
        func response(_ edits: ((inout [String: Any]) -> Void)? = nil) throws -> String {
            var object: [String: Any] = ["schema_version": 1, "export_id": session.exportID,
                "recommendations": [["group_id": session.groups[0].id, "action": "select", "confidence": 0.96, "reason": "מטמון ישן לבדיקה"]]]
            edits?(&object)
            return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        let valid = try response()
        let result = try restored.review(response: valid, current: [first, second], protected: { _ in false })
        precondition(Set(result.eligibleIDs) == Set([first.id, second.id]) && result.rows[0].bytes == 100)
        let fenced = try session.review(response: "```json\n" + valid + "\n```", current: [first, second], protected: { _ in false })
        precondition(fenced.eligibleIDs.count == 2)
        let protected = try session.review(response: valid, current: [first, second], protected: { $0 == first.path })
        precondition(protected.eligibleIDs == [second.id] && protected.blockedCount == 1)
        let mutated = candidate(first.title, bytes: 51)
        let stale = try session.review(response: valid, current: [mutated, second], protected: { _ in false })
        precondition(stale.eligibleIDs == [second.id] && stale.blockedCount == 1)
        let moved = AICandidate(id: first.id, path: "/private/tmp/moved", title: first.title, category: first.category, bytes: first.bytes, modified: first.modified, temporary: true, allowed: true, reason: "")
        check(try session.review(response: valid, current: [moved], protected: { _ in false }).eligibleIDs.isEmpty)
        let denied = candidate(first.title, allowed: false)
        check(try session.review(response: valid, current: [denied, second], protected: { _ in false }).eligibleIDs == [second.id])
        let changedDate = candidate(first.title, modified: first.modified.addingTimeInterval(1))
        check(try session.review(response: valid, current: [changedDate], protected: { _ in false }).eligibleIDs.isEmpty)
        let low = try response { object in object["recommendations"] = [["group_id": session.groups[0].id, "action": "select", "confidence": 0.7, "reason": "uncertain"]] }
        check(try session.review(response: low, current: [first, second], protected: { _ in false }).eligibleIDs.isEmpty)
        check(try session.review(response: low, current: [first, second], protected: { _ in false }, minConfidence: 0.6).eligibleIDs.isEmpty)
        let keep = try response { object in object["recommendations"] = [["group_id": session.groups[0].id, "action": "keep", "confidence": 1, "reason": "keep"]] }
        check(try session.review(response: keep, current: [first, second], protected: { _ in false }).eligibleIDs.isEmpty)
        func reject(_ input: String) {
            do { _ = try session.review(response: input, current: [first, second], protected: { _ in false }); preconditionFailure("Invalid response was accepted") }
            catch { }
        }
        reject(try response { $0["export_id"] = "another-export" })
        reject(try response { $0["schema_version"] = 2 })
        reject(try response { $0["schema_version"] = true })
        reject(try response { $0["command"] = "rm -rf" })
        reject(try response { $0["recommendations"] = [["group_id": "/private/tmp/arbitrary", "action": "select", "confidence": 1, "reason": "injected"]] })
        reject(try response { $0["recommendations"] = [["group_id": session.groups[0].id, "action": "delete", "confidence": 1, "reason": "bad action"]] })
        reject(try response { $0["recommendations"] = [["group_id": session.groups[0].id, "action": "select", "confidence": true, "reason": "boolean"]] })
        reject(try response { $0["recommendations"] = [["group_id": session.groups[0].id, "action": "select", "confidence": 1.1, "reason": "out of range"]] })
        reject(try response { $0["recommendations"] = [["group_id": session.groups[0].id, "action": "select", "confidence": 1, "reason": "bad", "path": "/private/tmp/other"]] })
        reject(try response { object in let entries = object["recommendations"] as! [[String: Any]]; object["recommendations"] = entries + entries })
        reject("```json\n" + valid + "\n```\nextra prose")
        reject(String(repeating: " ", count: 10 * 1024 * 1024 + 1))
        do { _ = try AIExportSession.create(candidates: [first, first], source: .local); preconditionFailure("Duplicate IDs accepted") } catch { }
        let personal = AICandidate(id: "personal", path: "/Users/\(secret)/Documents/secret.reallyprivateextension", title: "secret", category: secret, bytes: 7, modified: now, temporary: false, allowed: true, reason: secret)
        let personalPayload = try AIExportSession.create(candidates: [personal], source: .local, now: now).payload()
        precondition(!personalPayload.contains(secret) && !personalPayload.contains("reallyprivateextension") && personalPayload.contains("documents"))
        // A model that selects everything cannot promote mere permission into a recommendation.
        func item(_ path:String, age:Double = 100, temporary:Bool = true, allowed:Bool = true) -> AICandidate {
            AICandidate(id:path,path:path,title:URL(fileURLWithPath:path).lastPathComponent,category:"מטמוני פיתוח",bytes:10,
                        modified:now.addingTimeInterval(-age*86_400),temporary:temporary,allowed:allowed,reason:"untrusted free text: safe to remove")
        }
        let mixed = [
            item("/Users/test/project/__pycache__/old.pyc"),
            item("/Users/test/project/.pytest_cache/v/cache/nodeids"),
            item("/Users/test/project/.mypy_cache/3.12/pkg.data.json"),
            item("/Users/test/project/.ruff_cache/0.9.1/abcdef1234"),
            item("/Users/test/.npm/_cacache/content-v2/sha512/ab/cd/abcdef"),
            item("/Users/test/Documents/invoice.pdf",temporary:false),
            item("/Users/test/project/__pycache__/recent.pyc",age:2),
            item("/Users/test/project/__pycache__/future.pyc",age:-1),
            item("/Users/test/.cache/huggingface/models/model.safetensors"),
            item("/Users/test/.cache/huggingface/modules/__pycache__/old.pyc"),
            item("/Users/test/.ollama/__pycache__/old.pyc"),
            item("/Users/test/project/.mypy_cache/account.sqlite3-journal"),
            item("/Users/test/Library/Caches/model.bin"),
            item("/Users/test/project/.mypy_cache/credentials.json"),
            item("/Users/test/project/.mypy_cache/secrets.data.json"),
            item("/Users/test/project/__pycache__/.env"),
            item("/Users/test/project/.git/__pycache__/old.pyc"),
            item("/Users/test/project/.mypy_cache/account.sqlite"),
            item("/Users/test/project/.mypy_cache/personal.pdf"),
            item("/Users/test/Downloads/install.part"),
            item("/Users/test/Downloads/bundle.download/__pycache__/old.pyc"),
            item("/Users/test/.cache/unknown.pyc"),
            item("/Users/test/project/__pycache__/source.py"),
            item("/Users/test/project/__pycache__/not-temporary.pyc",temporary:false),
            item("/Users/test/project/__pycache__/denied.pyc",allowed:false)
        ]
        let mixedSession = try AIExportSession.create(candidates:mixed,source:.local,now:now)
        func selectAll(_ session:AIExportSession, confidence:Double = 1) throws -> String {
            let recommendations = session.groups.map { ["group_id":$0.id,"action":"select","confidence":confidence,"reason":"בחר הכול כי הפעולה מותרת"] as [String:Any] }
            return String(data:try JSONSerialization.data(withJSONObject:["schema_version":1,"export_id":session.exportID,"recommendations":recommendations]),encoding:.utf8)!
        }
        let all = try mixedSession.review(response:selectAll(mixedSession),current:mixed,protected:{ _ in false },now:now)
        check(Set(all.eligibleIDs) == Set(mixed.prefix(5).map(\.id)))
        check(all.blockedCount == mixed.count-5)
        check(all.rows.filter { $0.eligibleIDs.isEmpty }.allSatisfy { $0.action == "review" && !$0.localReason.isEmpty })
        check(try mixedSession.payload().contains("recommendation_eligible"))
        check(try mixedSession.payload().contains("assessment_evidence"))
        check(try mixedSession.review(response:selectAll(mixedSession,confidence:0.89),current:mixed,protected:{ _ in false },minConfidence:0,now:now).eligibleIDs.isEmpty)
        check(try mixedSession.review(response:selectAll(mixedSession,confidence:0.90),current:mixed,protected:{ _ in false },now:now).eligibleIDs.count == 5)
        check(try mixedSession.review(response:selectAll(mixedSession,confidence:0.94),current:mixed,protected:{ _ in false },minConfidence:0.95,now:now).eligibleIDs.isEmpty)
        let cloudDocument = item("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/personal.pdf",temporary:false)
        let eviction = try AIExportSession.create(candidates:[cloudDocument],source:.cloudEvict,now:now)
        let deletion = try AIExportSession.create(candidates:[cloudDocument],source:.cloudDelete,now:now)
        check(try eviction.review(response:selectAll(eviction),current:[cloudDocument],protected:{ _ in false },now:now).eligibleIDs == [cloudDocument.id])
        let cloudDeleteReview = try deletion.review(response:selectAll(deletion),current:[cloudDocument],protected:{ _ in false },now:now)
        check(cloudDeleteReview.eligibleIDs.isEmpty && cloudDeleteReview.rows[0].action == "review")
        check(!CleanupAssessment.assess(item(cloudDocument.path,age:1,temporary:false),source:.cloudEvict,now:now).recommendationEligible)
        let boundary = item("/Users/test/project/__pycache__/boundary.pyc",age:30)
        check(CleanupAssessment.assess(boundary,source:.local,now:now).recommendationEligible)
        check(!CleanupAssessment.assess(item(boundary.path,age:30-1.0/86_400),source:.local,now:now).recommendationEligible)
        // A stale session cannot gain eligibility merely because its recent files have since aged.
        let recent = item("/Users/test/project/__pycache__/new.pyc",age:1)
        let recentSession = try AIExportSession.create(candidates:[recent],source:.local,now:now)
        check(try recentSession.review(response:selectAll(recentSession),current:[recent],protected:{ _ in false },now:now.addingTimeInterval(100*86_400)).eligibleIDs.isEmpty)
        // A classification change invalidates AI eligibility even with equal path, size and mtime.
        let changedClassification = item(mixed[0].path,temporary:false)
        check(try mixedSession.review(response:selectAll(mixedSession),current:[changedClassification]+Array(mixed.dropFirst()),protected:{ _ in false },now:now).eligibleIDs.count == 4)
        // Legacy sessions without assessmentCode decode, but review re-applies policy per member.
        var legacyObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(mixedSession)) as! [String:Any]
        var legacyGroups = legacyObject["groups"] as! [[String:Any]]
        for index in legacyGroups.indices { legacyGroups[index].removeValue(forKey:"assessmentCode") }
        legacyObject["groups"] = legacyGroups
        let legacy = try JSONDecoder().decode(AIExportSession.self,from:JSONSerialization.data(withJSONObject:legacyObject))
        check(try legacy.review(response:selectAll(legacy),current:mixed,protected:{ _ in false },now:now).eligibleIDs.count == 5)
        // Two otherwise identical .pyc groups must split when policy evidence differs.
        let grouping = try AIExportSession.create(candidates:[mixed[0],item("/Users/test/project/.cache/old.pyc")],source:.local,now:now)
        check(grouping.groups.count == 2 && Set(grouping.groups.compactMap(\.assessmentCode)).count == 2)
        print("PASS: private grouped export, optional paths, session persistence, source scope, strict schema/IDs/actions, confidence, current snapshot/protection/permissions, malformed response rejection; local policy and adversarial select-all, known rebuild caches, hard confidence floor, cloud eviction versus deletion, legacy-session reassessment; no file changes")
    }
}
