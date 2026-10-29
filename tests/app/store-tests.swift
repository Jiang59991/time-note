import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Tests use only new temporary directories and an injected clock. No user data paths.
@MainActor
private final class StoreTests {
    private(set) var checks = 0
    private let base = Date(timeIntervalSince1970: 1_770_000_000.125)
    private var baseMS: Double { base.timeIntervalSince1970 * 1_000 }

    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
        checks += 1
    }

    func rejects(_ message: String, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch is StoreEngineError { checks += 1; return }
        catch { throw TestFailure(description: "\(message): unexpected error \(error)") }
        throw TestFailure(description: "\(message): invalid operation was accepted")
    }

    func encoded(_ object: [String: Any], sorted: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: sorted ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes])
    }

    func decoded(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(description: "Expected JSON object")
        }
        return object
    }

    func command(_ type: String, _ fields: [String: Any] = [:], operationID: String = UUID().uuidString) throws -> Data {
        var result = fields
        result["type"] = type
        result["operationID"] = operationID
        return try encoded(result)
    }

    func start(_ title: String = "写论文", mode: String = "countup", minutes: Int = 25,
               category: String = "work", manual: Bool = false, operationID: String = UUID().uuidString) throws -> Data {
        try command("start", ["title": title, "category": category, "categoryManual": manual,
                              "mode": mode, "minutes": minutes], operationID: operationID)
    }

    func recordRows(_ snapshot: [String: Any]) -> [[String: Any]] { snapshot["records"] as! [[String: Any]] }
    func row(_ snapshot: [String: Any], _ index: Int = 0) -> [String: Any] { recordRows(snapshot)[index] }
    func number(_ row: [String: Any], _ key: String) -> Double { (row[key] as! NSNumber).doubleValue }
    func revision(_ snapshot: [String: Any]) -> Int { (snapshot["revision"] as! NSNumber).intValue }
    func target(_ row: [String: Any]) -> [String: Any] { ["id": row["id"]!, "expectedRevision": row["revision"]!] }
    func date(_ offset: Double) -> Date { base.addingTimeInterval(offset) }

    func editFields(_ row: [String: Any], changes: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["id": row["id"]!, "expectedRevision": row["revision"]!,
            "title": row["title"]!, "category": row["category"]!, "categoryManual": row["categoryManual"]!,
            "start": row["start"]!, "end": row["end"]!, "minutes": row["minutes"]!, "completionIntent": "preserve"]
        result.merge(changes, uniquingKeysWith: { _, new in new })
        return result
    }

    final class Fixture {
        let directory: URL
        var url: URL { directory.appendingPathComponent("store.json") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("TimeNoteStoreTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    func emptyAndIndependentTimers() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let empty = try decoded(await engine.snapshot(now: base))
        try check(revision(empty) == 0 && recordRows(empty).isEmpty, "New stores are actually empty")
        try check((empty["todos"] as! [String: Any]).isEmpty && (empty["categoryMemory"] as! [String: Any]).isEmpty, "No seeded todos or memory")
        try check(number(empty, "now") == baseMS && empty["receipts"] == nil, "Snapshot clock is injected and receipts stay private")
        var snapshot = try decoded(await engine.execute(start(), now: base))
        snapshot = try decoded(await engine.execute(start(mode: "pomodoro", minutes: 1), now: date(10)))
        snapshot = try decoded(await engine.execute(start(mode: "pomodoro", minutes: 2), now: date(20)))
        let rows = recordRows(snapshot)
        try check(rows.count == 3 && rows.allSatisfy { $0["end"] is NSNull }, "Ordinary and multiple pomodoros run simultaneously")
        let identities = rows.flatMap { [$0["id"] as! String, $0["runID"] as! String] }
        try check(Set(identities).count == 6, "Same-name timers have separate record and run IDs")
        try check(rows[0]["deadline"] is NSNull && rows[0]["finishReason"] is NSNull, "Null fields are explicitly emitted")
        try check(number(rows[1], "deadline") == baseMS + 70_000 && number(rows[2], "deadline") == baseMS + 140_000, "Each pomo owns its deadline")
        snapshot = try decoded(await engine.snapshot(now: date(80)))
        let after = recordRows(snapshot)
        try check(after[0]["end"] is NSNull && after[2]["end"] is NSNull, "One deadline does not finish other tasks")
        try check(number(after[1], "end") == baseMS + 70_000 && after[1]["finishReason"] as? String == "deadline", "Delayed reconcile caps at actual deadline")
        try check(revision(snapshot) == 4 && number(after[1], "revision") == 2, "Reconcile increments revisions once")
        let repeated = try decoded(await engine.snapshot(now: date(90)))
        try check(revision(repeated) == revision(snapshot), "Repeated reconcile is idempotent")
        snapshot = try decoded(await engine.execute(command("finish", target(after[0])), now: date(100)))
        try check(number(row(snapshot), "end") == baseMS + 100_000 && row(snapshot, 2)["end"] is NSNull, "Finish affects only selected ordinary timer")
        snapshot = try decoded(await engine.execute(command("delete", target(row(snapshot, 2))), now: date(101)))
        try check(recordRows(snapshot).count == 2 && recordRows(snapshot).allSatisfy { !($0["end"] is NSNull) }, "Delete cancels only selected active run")
        try check(Set(recordRows(snapshot).map { $0["id"] as! String }) == Set(rows.prefix(2).map { $0["id"] as! String }), "Delete preserves other timer identities")
        let backup = try decoded(await engine.exportBackup())
        try check(backup["now"] == nil && (backup["receipts"] as! [[String: Any]]).count == 5, "Full export contains committed retry journal and no render clock")
    }

    func persistenceAndLocks() async throws {
        let fixture = try Fixture()
        var engine: StoreEngine? = try StoreEngine(url: fixture.url)
        let operation = try start("持久化", mode: "pomodoro", minutes: 1)
        let started = try decoded(await engine!.execute(operation, now: base))
        _ = try await engine!.execute(start("跨重启普通计时"), now: date(1))
        try await rejects("Second writer in same process is refused") { _ = try StoreEngine(url: fixture.url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--probe-lock", fixture.url.path]
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        try check(process.terminationStatus == 73, "File lock excludes separate processes")
        weak let released = engine
        engine = nil
        try check(released == nil, "Engine releases file lock when its lifetime ends")
        let reopened = try StoreEngine(url: fixture.url)
        let loaded = try decoded(await reopened.snapshot(now: date(120)))
        try check(recordRows(loaded).count == 2 && row(loaded)["id"] as? String == row(started)["id"] as? String, "Cold restart preserves canonical IDs")
        try check(number(row(loaded), "end") == baseMS + 60_000 && row(loaded, 1)["end"] is NSNull, "Restart closes overdue pomo and resumes ordinary run")
        let replayed = try decoded(await reopened.execute(operation, now: date(121)))
        try check(recordRows(replayed).count == 2 && revision(replayed) == revision(loaded), "Operation receipts survive restart")
        let beforeRollback = revision(replayed)
        let rollback = try decoded(await reopened.snapshot(now: date(-100)))
        try check(revision(rollback) == beforeRollback && row(rollback, 1)["end"] is NSNull, "Wall clock rollback never creates negative finish or deletes active run")
    }

    func idempotencyAndCAS() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let id = UUID().uuidString
        let firstPayload = try start("幂等", operationID: id)
        let first = try decoded(await engine.execute(firstPayload, now: base))
        let firstRecord = row(first)
        var snapshot = try decoded(await engine.execute(start("其他任务"), now: date(1)))
        let revisionBefore = revision(snapshot)
        let reordered = try JSONSerialization.data(withJSONObject: decoded(firstPayload), options: [.prettyPrinted])
        snapshot = try decoded(await engine.execute(reordered, now: date(2)))
        try check(recordRows(snapshot).count == 2 && revision(snapshot) == revisionBefore, "Identical operation with another key order does not duplicate")
        try check(number(snapshot, "now") == baseMS + 2_000 && row(snapshot, 1)["title"] as? String == "其他任务", "Replay returns current snapshot and current clock")
        let bytes = try Data(contentsOf: fixture.url)
        try await rejects("Same operation ID with changed content fails") { _ = try await engine.execute(self.start("不同内容", operationID: id), now: self.date(3)) }
        try check(try Data(contentsOf: fixture.url) == bytes, "Operation conflict leaves disk unchanged")
        snapshot = try decoded(await engine.execute(command("edit", editFields(firstRecord, changes: ["title": "改名"])), now: date(4)))
        try check(number(row(snapshot), "revision") == 2, "Edit advances target revision")
        let newBytes = try Data(contentsOf: fixture.url)
        for kind in ["finish", "delete"] {
            try await rejects("Stale \(kind) rejected") { _ = try await engine.execute(self.command(kind, self.target(firstRecord)), now: self.date(5)) }
        }
        try await rejects("Stale edit rejected") { _ = try await engine.execute(self.command("edit", self.editFields(firstRecord)), now: self.date(5)) }
        try check(try Data(contentsOf: fixture.url) == newBytes, "Stale targets do not mutate disk or receipt journal")
        try await rejects("Unknown target rejected") { _ = try await engine.execute(self.command("delete", ["id": UUID().uuidString, "expectedRevision": 1]), now: self.date(6)) }
        let final = try decoded(await engine.snapshot(now: date(6)))
        try check(row(final)["title"] as? String == "改名" && revision(final) == revision(snapshot), "Stale actions leave memory unchanged")
    }

    func simultaneousCommands() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let when = base
        let requests = try (0..<24).map { try start("并行同名任务", mode: $0.isMultiple(of: 2) ? "pomodoro" : "countup") }
        let results = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for request in requests { group.addTask { try await engine.execute(request, now: when) } }
            var collected: [Data] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        let snapshot = try decoded(await engine.snapshot(now: when))
        try check(recordRows(snapshot).count == 24 && revision(snapshot) == 24, "Concurrent starts all commit without lost updates")
        let revisions = try results.map { revision(try decoded($0)) }
        try check(Set(revisions) == Set(1...24), "Concurrent responses each have a unique monotonically committed revision")
        try check(Set(recordRows(snapshot).map { $0["id"] as! String }).count == 24, "Concurrent same-name starts remain independently addressable")
        let retry = try start("同一操作并发重试")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { _ = try await engine.execute(retry, now: when) } }
            try await group.waitForAll()
        }
        let afterRetries = try decoded(await engine.snapshot(now: when))
        try check(recordRows(afterRetries).count == 25 && revision(afterRetries) == 25, "Concurrent identical retries create exactly one timer")
        let selected = row(afterRetries)
        let conflicting = try ["先提交", "后提交"].map { try command("edit", editFields(selected, changes: ["title": $0])) }
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for request in conflicting {
                group.addTask {
                    do { _ = try await engine.execute(request, now: when); return true }
                    catch { return false }
                }
            }
            var values: [Bool] = []
            for await outcome in group { values.append(outcome) }
            return values
        }
        try check(outcomes.filter { $0 }.count == 1, "Concurrent edits sharing one expected revision have exactly one winner")
        let afterConflict = try decoded(await engine.snapshot(now: when))
        try check(revision(afterConflict) == 26 && number(row(afterConflict), "revision") == 2, "Failed concurrent edit does not increment revision or partially apply")
    }

    func editTimeSemantics() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        var snapshot = try decoded(await engine.execute(start("精确时间", mode: "pomodoro", minutes: 25), now: base))
        let original = row(snapshot), startTime = number(original, "start")
        snapshot = try decoded(await engine.execute(command("edit", editFields(original, changes: ["title": "新的标题", "category": "create", "categoryManual": true])), now: date(100)))
        let renamed = row(snapshot)
        try check(number(renamed, "start") == startTime && number(renamed, "deadline") == startTime + 25 * 60_000, "Metadata edit keeps exact millisecond timestamps")
        try check(renamed["runID"] as? String == original["runID"] as? String && renamed["end"] is NSNull, "Edit retains run identity and active state")
        let altered = editFields(renamed, changes: ["minutes": 1])
        let before = try Data(contentsOf: fixture.url)
        try await rejects("Recomputed elapsed deadline needs confirmation") { _ = try await engine.execute(self.command("edit", altered), now: self.date(100)) }
        try check(try Data(contentsOf: fixture.url) == before, "Unconfirmed new deadline is not saved")
        var confirmed = altered; confirmed["completionIntent"] = "deadline"
        snapshot = try decoded(await engine.execute(command("edit", confirmed), now: date(100)))
        let finished = row(snapshot)
        try check(number(finished, "end") == startTime + 60_000 && finished["finishReason"] as? String == "deadline", "Confirmed deadline edit ends exactly at recalculated deadline")
        try check(finished["title"] as? String == "新的标题" && finished["category"] as? String == "create", "Deadline finish retains newly saved metadata")
        try await rejects("Completed record cannot reopen") { _ = try await engine.execute(self.command("edit", self.editFields(finished, changes: ["end": NSNull()])), now: self.date(110)) }
        snapshot = try decoded(await engine.execute(command("edit", editFields(finished, changes: ["end": baseMS + 100_000])), now: date(110)))
        try check(number(row(snapshot), "end") == baseMS + 100_000 && row(snapshot)["finishReason"] as? String == "corrected", "Historical correction may exceed old pomo deadline")
        try check(number(row(snapshot), "deadline") == baseMS + 60_000, "Historical correction preserves original deadline fact")
        snapshot = try decoded(await engine.execute(command("edit", editFields(row(snapshot), changes: ["title": "完成后改名"])), now: date(111)))
        try check(number(row(snapshot), "end") == baseMS + 100_000 && number(row(snapshot), "start") == startTime, "Completed metadata edit does not round timestamps")

        snapshot = try decoded(await engine.execute(start("普通编辑"), now: date(120)))
        let ordinary = row(snapshot, 1)
        try await rejects("Running end without finish intent rejected") { _ = try await engine.execute(self.command("edit", self.editFields(ordinary, changes: ["end": self.baseMS + 121_000])), now: self.date(122)) }
        snapshot = try decoded(await engine.execute(command("edit", editFields(ordinary, changes: ["end": baseMS + 121_000, "completionIntent": "finish", "title": "保存并结束"])), now: date(122)))
        try check(number(row(snapshot, 1), "end") == baseMS + 121_000 && row(snapshot, 1)["title"] as? String == "保存并结束", "Explicit finish edit atomically saves metadata and ends target")

        let explicitFixture = try Fixture(), explicit = try StoreEngine(url: explicitFixture.url)
        let explicitStart = try decoded(await explicit.execute(start("明确修正", mode: "pomodoro", minutes: 25), now: base))
        let explicitEnd = baseMS + 99_000
        let explicitlyFinished = try decoded(await explicit.execute(command("edit", editFields(row(explicitStart), changes: [
            "start": baseMS - 3_600_000, "minutes": 1, "end": explicitEnd, "completionIntent": "finish"
        ])), now: date(100)))
        try check(number(row(explicitlyFinished), "end") == explicitEnd && row(explicitlyFinished)["finishReason"] as? String == "corrected", "Explicit actual end wins when a corrected start moves new deadline into the past")
        try check(number(row(explicitlyFinished), "deadline") == baseMS - 3_540_000, "Explicit finish keeps recomputed target separately from actual end")
        let earlyFixture = try Fixture(), early = try StoreEngine(url: earlyFixture.url)
        let earlyStart = try decoded(await early.execute(start(mode: "pomodoro", minutes: 25), now: base))
        let earlyEnd = try decoded(await early.execute(command("edit", editFields(row(earlyStart), changes: [
            "minutes": 1, "end": baseMS + 50_000, "completionIntent": "finish"
        ])), now: date(100)))
        try check(number(row(earlyEnd), "end") == baseMS + 50_000 && row(earlyEnd)["finishReason"] as? String == "manual", "Explicit early end remains exact even if recalculated deadline has since passed")
    }

    func originalDeadlineRaces() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let started = try decoded(await engine.execute(start("原截止", mode: "pomodoro", minutes: 1), now: base))
        let original = row(started)
        try await rejects("Edit cannot revive originally expired pomodoro") {
            _ = try await engine.execute(self.command("edit", self.editFields(original, changes: ["title": "不能提交", "minutes": 240])), now: self.date(90))
        }
        let snapshot = try decoded(await engine.snapshot(now: date(90)))
        try check(number(row(snapshot), "end") == baseMS + 60_000 && row(snapshot)["title"] as? String == "原截止", "Overdue edit commits original deadline but not new draft")
        try check(revision(snapshot) == 2 && number(row(snapshot), "revision") == 2, "Overdue edit reconciliation commits exactly once")
        let receipts = try decoded(await engine.exportBackup())["receipts"] as! [[String: Any]]
        try check(receipts.count == 1, "Failed overdue edit is not falsely receipted as success")
        let otherFixture = try Fixture(), other = try StoreEngine(url: otherFixture.url)
        let otherStart = try decoded(await other.execute(start("到点点击结束", mode: "pomodoro", minutes: 1), now: base))
        let ended = try decoded(await other.execute(command("finish", target(row(otherStart))), now: date(600)))
        try check(number(row(ended), "end") == baseMS + 60_000 && row(ended)["finishReason"] as? String == "deadline", "Late finish uses original deadline")
        let instantFixture = try Fixture(), instant = try StoreEngine(url: instantFixture.url)
        let accidental = try decoded(await instant.execute(start(), now: base))
        let removed = try decoded(await instant.execute(command("finish", target(row(accidental))), now: base))
        try check(recordRows(removed).isEmpty, "Exact zero-duration start-stop leaves no fake interval")
        let explicitFixture = try Fixture(), explicit = try StoreEngine(url: explicitFixture.url)
        let explicitStart = try decoded(await explicit.execute(start(mode: "pomodoro", minutes: 1), now: base))
        try await rejects("Explicit end cannot bypass original elapsed deadline") {
            _ = try await explicit.execute(self.command("edit", self.editFields(self.row(explicitStart), changes: [
                "minutes": 240, "end": self.baseMS + 80_000, "completionIntent": "finish"
            ])), now: self.date(90))
        }
        let explicitRejected = try decoded(await explicit.snapshot(now: date(90)))
        try check(number(row(explicitRejected), "end") == baseMS + 60_000 && row(explicitRejected)["finishReason"] as? String == "deadline", "Original deadline remains authoritative after rejected explicit end")
    }

    func categoryMemoryAndManual() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        var snapshot = try decoded(await engine.execute(start("  CAFE\u{301} \n", category: "create", manual: true), now: base))
        let memory = snapshot["categoryMemory"] as! [String: String]
        try check(memory == ["café": "create"] && row(snapshot)["title"] as? String == "CAFÉ", "Category memory trims, NFC normalizes, and lowercases titles")
        snapshot = try decoded(await engine.execute(start("café", category: "work", manual: false), now: date(1)))
        try check((snapshot["categoryMemory"] as! [String: String])["café"] == "create", "Automatic categorization does not overwrite explicit memory")
        snapshot = try decoded(await engine.execute(command("edit", editFields(row(snapshot, 1), changes: ["category": "life", "categoryManual": true])), now: date(2)))
        try check((snapshot["categoryMemory"] as! [String: String])["café"] == "life", "Manual category edit updates same normalized title key")
        snapshot = try decoded(await engine.execute(start("  \n", category: "other", manual: true), now: date(3)))
        try check(row(snapshot, 2)["title"] as? String == "未命名事项" && (snapshot["categoryMemory"] as! [String: String]).count == 1, "Blank timer uses fallback without polluting title memory")
        snapshot = try decoded(await engine.execute(command("manual", ["title": "跨午夜", "category": "sleep", "categoryManual": true, "start": baseMS - 30_000, "end": baseMS + 4_000]), now: date(5)))
        let manual = row(snapshot, 3)
        try check(manual["runID"] is NSNull && manual["deadline"] is NSNull && manual["mode"] as? String == "countup", "Manual record is completed history without active run")
        try check(number(manual, "end") - number(manual, "start") == 34_000, "Manual record stores exact interval rather than a day total")
        for category in ["work", "create", "move", "rest", "sleep", "dining", "daily", "life", "other"] {
            _ = try await engine.execute(start(category, category: category), now: date(6))
            checks += 1
        }
        for invalid in ["", "unknown", "科研", "WORK"] {
            try await rejects("Unknown category \(invalid)") { _ = try await engine.execute(self.start(category: invalid), now: self.date(7)) }
        }
        for (startTime, endTime) in [(baseMS, baseMS), (baseMS, baseMS - 1), (baseMS, baseMS + 100_000)] {
            try await rejects("Invalid manual interval rejected") {
                _ = try await engine.execute(self.command("manual", ["title": "错误", "category": "work", "categoryManual": false, "start": startTime, "end": endTime]), now: self.date(10))
            }
        }
    }

    func editableCategories() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        func labels(_ state: [String: Any]) -> [[String: Any]] { state["categories"] as! [[String: Any]] }
        var state = try decoded(await engine.snapshot(now: base))
        try check(labels(state).map { $0["name"] as! String } == ["科研", "自媒体", "运动", "娱乐", "睡眠", "餐饮", "生活", "杂事", "其他"], "Default labels include new life label without renaming legacy chores")
        _ = try await engine.execute(start("原有杂事", category: "life"), now: base)
        var legacy = try decoded(await engine.exportBackup()); legacy.removeValue(forKey: "categories")
        let legacyFixture = try Fixture(), legacyEngine = try StoreEngine(url: legacyFixture.url)
        let migrated = try decoded(await legacyEngine.importBackup(encoded(legacy), now: base))
        try check(labels(migrated).count == 9 && row(migrated)["category"] as? String == "life", "Legacy V1 backups gain defaults without rewriting existing category IDs")
        let add = try command("categoryAdd", ["name": "  学习  ", "color": "#bfdbfe"])
        state = try decoded(await engine.execute(add, now: base))
        let label = labels(state).first { $0["name"] as? String == "学习" }!, id = label["id"] as! String
        try check(UUID(uuidString: id) != nil && labels(state).last!["id"] as? String == "other", "Custom label gets stable native UUID and is inserted before fallback")
        let replay = try decoded(await engine.execute(add, now: base))
        try check(revision(state) == revision(replay) && labels(replay).count == 10, "Label add retries do not duplicate")
        for fields: [String: Any] in [["name":"学习", "color":"#bfdbfe"], ["name":"", "color":"#bfdbfe"], ["name":"a\nb", "color":"#bfdbfe"], ["name":String(repeating:"长",count:21), "color":"#bfdbfe"], ["name":"有效", "color":"#000000"]] {
            try await rejects("Invalid / duplicate category rejected") { _ = try await engine.execute(self.command("categoryAdd", fields), now: self.base) }
        }
        state = try decoded(await engine.execute(start("自定义标签记录", mode: "pomodoro", minutes: 1, category: id, manual: true), now: base))
        let running = row(state, 1)
        try check(running["category"] as? String == id && (state["categoryMemory"] as! [String: String])["自定义标签记录"] == id, "Custom label accepted and manual memory saved")
        state = try decoded(await engine.execute(command("categoryEdit", ["id":id,"expectedRevision":1,"name":"阅读学习","color":"#fecdd3"]), now: date(1)))
        let edited = labels(state).first { $0["id"] as? String == id }!
        try check(edited["name"] as? String == "阅读学习" && edited["color"] as? String == "#fecdd3" && number(row(state,1),"revision") == number(running,"revision"), "Rename / recolor preserve record facts and identity")
        try await rejects("Stale category edit rejected") { _ = try await engine.execute(self.command("categoryEdit", ["id":id,"expectedRevision":1,"name":"旧修改","color":"#bfdbfe"]), now: self.base) }
        let backup = try await engine.exportBackup(), restoredFixture = try Fixture(), restored = try StoreEngine(url: restoredFixture.url)
        let restoredState = try decoded(await restored.importBackup(backup, now: date(1)))
        try check(labels(restoredState).contains { $0["id"] as? String == id && $0["color"] as? String == "#fecdd3" }, "Backup import restores custom label name, ID and color")
        var malformed = try decoded(backup)
        var malformedLabels = labels(malformed); malformedLabels[0]["color"] = "url(evil)"; malformed["categories"] = malformedLabels
        let bytes = try encoded(malformed), diskBefore = try Data(contentsOf: fixture.url)
        try await rejects("Malformed category backup rejected") { _ = try await engine.importBackup(bytes, now: self.date(1)) }
        try check(try Data(contentsOf: fixture.url) == diskBefore, "Invalid label import leaves file intact")
        let unknown = UUID().uuidString
        try await rejects("Unregistered UUID is not a valid record category") { _ = try await engine.execute(self.start(category: unknown), now: self.date(2)) }
        try await rejects("Fallback name stays recognizable") { _ = try await engine.execute(self.command("categoryEdit",["id":"other","expectedRevision":0,"name":"重命名","color":"#bfdbfe"]),now:self.base) }
        let failingFixture = try Fixture(), failingEngine = try StoreEngine(url: failingFixture.url)
        let unchanged = try Data(contentsOf: failingFixture.url)
        try Data("blocked backup folder".utf8).write(to: failingFixture.url.deletingLastPathComponent().appendingPathComponent("Backups"))
        try await rejects("Label add write failure is not reported as success") { _ = try await failingEngine.execute(self.command("categoryAdd",["name":"失败标签","color":"#bfdbfe"]),now:self.base) }
        let failedState = try decoded(await failingEngine.snapshot(now: base))
        try check(labels(failedState).count == 9 && revision(failedState) == 0 && (try Data(contentsOf: failingFixture.url)) == unchanged, "Failed label commit leaves memory and disk unchanged")
        try await rejects("Fallback category cannot be deleted") { _ = try await engine.execute(self.command("categoryDelete",["id":"other","expectedRevision":0]),now:self.base) }
        // Deletion and due-pomodoro reconciliation share one commit and one row revision.
        state = try decoded(await engine.execute(command("categoryDelete", ["id":id,"expectedRevision":2]), now: date(61)))
        let moved = row(state,1)
        try check(moved["id"] as? String == running["id"] as? String && moved["category"] as? String == "other" && moved["finishReason"] as? String == "deadline", "Deleting label preserves due timer and reassigns it atomically")
        try check(number(moved,"revision") == number(running,"revision")+1 && !labels(state).contains { $0["id"] as? String == id }, "Deletion increments record once, removes label")
        try check((state["categoryMemory"] as! [String:String])["自定义标签记录"] == "other" && row(state)["category"] as? String == "life", "Deletion remaps only matching memory and preserves other records")
        try await rejects("Deleted label cannot receive new records") { _ = try await engine.execute(self.start(category:id),now:self.date(62)) }
    }

    func todosAndInputValidation() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: base)
        var snapshot = try decoded(await engine.execute(command("todoAdd", ["day": today, "title": "  读论文  "]), now: base))
        var todos = snapshot["todos"] as! [String: [[String: Any]]]
        let todo = todos[today]![0]
        try check(todo["title"] as? String == "读论文" && todo["done"] as? Bool == false && recordRows(snapshot).isEmpty, "Todo is independent of elapsed time records")
        let set = try command("todoSet", ["day": today, "id": todo["id"]!, "expectedRevision": todo["revision"]!, "done": true])
        snapshot = try decoded(await engine.execute(set, now: date(1)))
        let replay = try decoded(await engine.execute(set, now: date(2)))
        todos = replay["todos"] as! [String: [[String: Any]]]
        try check(todos[today]![0]["done"] as? Bool == true && revision(replay) == revision(snapshot), "Todo completion retry sets once instead of toggling")
        try await rejects("Todo stale update rejected") { _ = try await engine.execute(self.command("todoSet", ["day": today, "id": todo["id"]!, "expectedRevision": 1, "done": false]), now: self.date(3)) }
        try await rejects("Todo cannot move between date keys by changing target day") { _ = try await engine.execute(self.command("todoDelete", ["day": "2024-03-01", "id": todo["id"]!, "expectedRevision": 2]), now: self.date(3)) }
        snapshot = try decoded(await engine.execute(command("todoDelete", ["day": today, "id": todo["id"]!, "expectedRevision": 2]), now: date(4)))
        try check((snapshot["todos"] as! [String: Any]).isEmpty, "Deleting final todo removes empty date group")
        _ = try await engine.execute(command("todoAdd", ["day": "2099-12-31", "title": "未来计划"]), now: date(5))
        checks += 1
        for invalidDay in ["2023-02-29", "2024-13-01", "2024-04-31", "0000-01-01", "2024-2-01", "2024-01-01Z", "2024-00-01"] {
            try await rejects("Invalid calendar day \(invalidDay)") { _ = try await engine.execute(self.command("todoAdd", ["day": invalidDay, "title": "x"]), now: self.base) }
        }
        try await rejects("Blank todo rejected") { _ = try await engine.execute(self.command("todoAdd", ["day": "2024-01-01", "title": " \n"]), now: self.base) }
        for field in ["categoryManual", "minutes"] {
            var invalid = try decoded(start())
            invalid[field] = field == "categoryManual" ? 1 : true
            let data = try encoded(invalid)
            try await rejects("JSON bool and number distinguished for \(field)") { _ = try await engine.execute(data, now: self.base) }
        }
        for minutes in [0, 241, -1] {
            try await rejects("Pomo target outside 1...240") { _ = try await engine.execute(self.start(mode: "pomodoro", minutes: minutes), now: self.base) }
        }
        var extra = try decoded(start()); extra["surprise"] = true
        let extraData = try encoded(extra)
        try await rejects("Unknown command field rejected") { _ = try await engine.execute(extraData, now: self.base) }
        var fractional = try decoded(start()); fractional["minutes"] = 1.5
        let fractionalData = try encoded(fractional)
        try await rejects("Fractional minutes rejected") { _ = try await engine.execute(fractionalData, now: self.base) }
        try await rejects("Malformed JSON rejected") { _ = try await engine.execute(Data("{oops".utf8), now: self.base) }
        try await rejects("Array command rejected") { _ = try await engine.execute(Data("[]".utf8), now: self.base) }
        try await rejects("Nonfinite clock rejected") { _ = try await engine.snapshot(now: Date(timeIntervalSince1970: .infinity)) }
        try await rejects("Oversized command rejected") { _ = try await engine.execute(Data(repeating: 65, count: 128 * 1_024 + 1), now: self.base) }
    }

    func todoRollover() async throws {
        let historicalFixture = try Fixture()
        let historicalEngine = try StoreEngine(url: historicalFixture.url)
        let historical = try decoded(await historicalEngine.execute(command("todoAdd", ["day": "2020-01-01", "title": "补入未完成项"]), now: base))
        try check((historical["todos"] as! [String: [[String: Any]]])["2020-01-01"] == nil, "Historical add carries forward even as the first mutation")
        let fixture = try Fixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Calendar dates include DST transitions when run in America/New_York.
        let before = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59, second: 59))!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 12))!
        var pendingID = ""
        var carriedRevision = 0
        var oldCommand = Data()
        var backup = Data()
        do {
            let engine = try StoreEngine(url: fixture.url)
            _ = try await engine.execute(command("todoAdd", ["day": "2026-03-07", "title": "已完成"]), now: before)
            var snapshot = try decoded(await engine.snapshot(now: before))
            let completed = (snapshot["todos"] as! [String: [[String: Any]]])["2026-03-07"]![0]
            _ = try await engine.execute(command("todoSet", ["day": "2026-03-07", "id": completed["id"]!, "expectedRevision": completed["revision"]!, "done": true]), now: before)
            let add = try command("todoAdd", ["day": "2026-03-07", "title": "未完成"])
            snapshot = try decoded(await engine.execute(add, now: before))
            let pending = (snapshot["todos"] as! [String: [[String: Any]]])["2026-03-07"]![1]
            pendingID = pending["id"] as! String
            oldCommand = try command("todoDelete", ["day": "2026-03-07", "id": pendingID, "expectedRevision": pending["revision"]!])
            _ = try await engine.execute(command("todoAdd", ["day": "2026-03-08", "title": "今天计划"]), now: before)
            _ = try await engine.execute(command("todoAdd", ["day": "2026-03-12", "title": "未来计划"]), now: before)
            snapshot = try decoded(await engine.snapshot(now: midnight))
            let todos = snapshot["todos"] as! [String: [[String: Any]]]
            try check(todos["2026-03-07"]!.count == 1 && todos["2026-03-07"]![0]["done"] as? Bool == true, "Completed Todos remain only on their original day")
            let carried = todos["2026-03-08"]!
            carriedRevision = carried[0]["revision"] as! Int
            try check(carried.count == 2 && carried[0]["id"] as? String == pendingID && carriedRevision == 2, "Midnight moves unfinished Todo with stable ID, advances revision, preserves today's plans")
            let replay = try decoded(await engine.execute(add, now: midnight))
            try check(revision(replay) == revision(snapshot), "Rollover and operation retries never duplicate Todos or write again")
            try await rejects("Pre-midnight stale command cannot delete a moved Todo") { _ = try await engine.execute(oldCommand, now: midnight) }
            backup = try await engine.exportBackup()
        }
        do {
            let engine = try StoreEngine(url: fixture.url)
            let snapshot = try decoded(await engine.snapshot(now: later))
            let todos = snapshot["todos"] as! [String: [[String: Any]]]
            try check(todos["2026-03-08"] == nil && todos["2026-03-11"]!.count == 2 && todos["2026-03-12"]!.count == 1, "Cold reopen skips missed days and leaves future plans alone")
            let pending = todos["2026-03-11"]![0]
            try check(pending["id"] as? String == pendingID && pending["revision"] as? Int == carriedRevision + 1 && recordRows(snapshot).isEmpty, "Reopen preserves identity and never creates time records")
            _ = try await engine.execute(command("todoSet", ["day": "2026-03-11", "id": pendingID, "expectedRevision": pending["revision"]!, "done": true]), now: later)
            let imported = try decoded(await engine.importBackup(backup, now: later))
            try check((imported["todos"] as! [String: [[String: Any]]])["2026-03-11"]!.count == 2, "Import reconciles overdue Todos as well")
        }
    }

    func importsAndAtomicValidation() async throws {
        let sourceFixture = try Fixture(), source = try StoreEngine(url: sourceFixture.url)
        _ = try await source.execute(start("导入番茄", mode: "pomodoro", minutes: 1, category: "create", manual: true), now: base)
        _ = try await source.execute(command("todoAdd", ["day": "2026-01-31", "title": "保留待办"]), now: date(1))
        let backup = try await source.exportBackup(), good = try decoded(backup)
        let preview = try StoreEngine.validateBackup(backup, now: date(2))
        try check(preview.records == 1 && preview.todos == 1, "Read-only preview validates and counts real data")
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        for index in 0..<5 { _ = try await engine.execute(start("原数据\(index)"), now: base) }
        let oldDisk = try Data(contentsOf: fixture.url)
        var invalidBackups: [(String, [String: Any])] = []
        func changed(_ name: String, _ mutate: (inout [String: Any]) -> Void) {
            var copy = good; mutate(&copy); invalidBackups.append((name, copy))
        }
        func changedRecord(_ name: String, _ mutate: (inout [String: Any]) -> Void) {
            changed(name) { copy in
                var rows = copy["records"] as! [[String: Any]]; mutate(&rows[0]); copy["records"] = rows
            }
        }
        changed("Unsupported schema") { $0["schemaVersion"] = 2 }
        changed("Unknown root key") { $0["now"] = baseMS }
        changed("Missing receipts") { $0.removeValue(forKey: "receipts") }
        changed("Global revision below row") { $0["revision"] = 0 }
        changed("Fractional global revision") { $0["revision"] = 2.5 }
        changed("Revision beyond JavaScript safe integer") { $0["revision"] = Int64(9_007_199_254_740_992) }
        changed("Revision cannot increment beyond JavaScript safe integer") { $0["revision"] = Int64(9_007_199_254_740_991) }
        changed("Duplicate record ID") { $0["records"] = [self.row(good), self.row(good)] }
        changed("Non-normalized memory") { $0["categoryMemory"] = [" ABC ": "work"] }
        changed("Unknown memory category") { $0["categoryMemory"] = ["abc": "eighth"] }
        changed("Invalid todo date") { $0["todos"] = ["2026-02-30": []] }
        changed("Todo ID collides with run") {
            var grouped = $0["todos"] as! [String: [[String: Any]]]
            let day = grouped.keys.first!
            grouped[day]![0]["id"] = self.row(good)["runID"]!
            $0["todos"] = grouped
        }
        changed("Duplicate operation receipt") {
            let receipts = $0["receipts"] as! [[String: Any]]; $0["receipts"] = [receipts[0], receipts[0]]
        }
        changed("Receipt payload mismatch") {
            var receipts = $0["receipts"] as! [[String: Any]]; receipts[0]["operationID"] = UUID().uuidString; $0["receipts"] = receipts
        }
        changed("Receipt revision invalid") {
            var receipts = $0["receipts"] as! [[String: Any]]; receipts[1]["committedRevision"] = 1; $0["receipts"] = receipts
        }
        changedRecord("Unknown record field") { $0["unsupported"] = "x" }
        changedRecord("Missing explicit null end") { $0.removeValue(forKey: "end") }
        changedRecord("Unknown category") { $0["category"] = "unknown" }
        changedRecord("Unknown mode") { $0["mode"] = "hourglass" }
        changedRecord("Bad UUID") { $0["id"] = "not-an-id" }
        changedRecord("Record ID collides with own run") { $0["id"] = $0["runID"] }
        changedRecord("Open record without run") { $0["runID"] = NSNull() }
        changedRecord("Open record with finish reason") { $0["finishReason"] = "manual" }
        changedRecord("Incorrect open deadline") { $0["deadline"] = baseMS + 10_000 }
        changedRecord("Future record start") { $0["start"] = baseMS + 500_000; $0["deadline"] = baseMS + 560_000 }
        changedRecord("Future record end") { $0["end"] = baseMS + 500_000; $0["finishReason"] = "corrected" }
        changedRecord("End before start") { $0["end"] = baseMS - 1; $0["finishReason"] = "corrected" }
        changedRecord("Finished without reason") { $0["end"] = baseMS + 1 }
        changedRecord("Deadline reason mismatches end") { $0["end"] = baseMS + 1; $0["finishReason"] = "deadline" }
        changedRecord("Row revision above global") { $0["revision"] = 99 }
        changedRecord("Boolean in numeric start") { $0["start"] = true }
        changedRecord("Number in boolean categoryManual") { $0["categoryManual"] = 1 }
        changedRecord("Oversized title") { $0["title"] = String(repeating: "a", count: 501) }
        for (name, invalid) in invalidBackups {
            let data = try encoded(invalid)
            try await rejects("Import: \(name)") { _ = try await engine.importBackup(data, now: self.date(120)) }
            try check(try Data(contentsOf: fixture.url) == oldDisk, "Failed import leaves bytes intact: \(name)")
        }
        let unchanged = try decoded(await engine.snapshot(now: date(120)))
        try check(recordRows(unchanged).count == 5 && revision(unchanged) == 5, "Bad imports leave actor memory intact")
        let imported = try decoded(await engine.importBackup(backup, now: date(120)))
        try check(revision(imported) == 6 && recordRows(imported).count == 1, "Import replacement revision exceeds local prior revision")
        try check(number(row(imported), "end") == baseMS + 60_000 && row(imported)["finishReason"] as? String == "deadline", "Import reconciles overdue pomo once before commit")
        try check((imported["categoryMemory"] as! [String: String])["导入番茄"] == "create", "Full backup round trip preserves category memory")
        let backupFiles = try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        try check(try backupFiles.contains { try Data(contentsOf: $0) == oldDisk }, "Import keeps exact prior full store in recovery backups")
        var highRevision = good; highRevision["revision"] = 100
        let high = try decoded(await engine.importBackup(encoded(highRevision), now: date(120)))
        try check(revision(high) == 101, "Import revision exceeds imported source revision too")
        let exported = try await engine.exportBackup()
        let fullPreview = try StoreEngine.validateBackup(exported, now: date(121))
        try check(fullPreview.records == 1 && fullPreview.todos == 1, "Re-exported reconciled backup remains valid")
    }

    func fileFailuresAndRecovery() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let initial = try Data(contentsOf: fixture.url)
        let backupDirectory = fixture.directory.appendingPathComponent("Backups")
        try Data("blocker".utf8).write(to: backupDirectory)
        try await rejects("Backup path occupied by a file aborts mutation") { _ = try await engine.execute(self.start(), now: self.base) }
        try check(try Data(contentsOf: fixture.url) == initial, "Backup failure preserves old disk")
        try check(recordRows(try decoded(await engine.snapshot(now: base))).isEmpty, "Backup failure preserves old actor state")
        try FileManager.default.removeItem(at: backupDirectory)
        let elsewhere = fixture.directory.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: backupDirectory, withDestinationURL: elsewhere)
        try await rejects("Symlink backup directory refused") { _ = try await engine.execute(self.start(), now: self.base) }
        try check(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty, "No backup is written through a substituted directory symlink")
        try FileManager.default.removeItem(at: backupDirectory)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        guard chmod(backupDirectory.path, 0o500) == 0 else { throw TestFailure(description: "Could not set backup permissions") }
        try await rejects("Read-only backup folder aborts mutation") { _ = try await engine.execute(self.start(), now: self.base) }
        _ = chmod(backupDirectory.path, 0o700)
        try check(try Data(contentsOf: fixture.url) == initial, "Backup permission error leaves disk unchanged")
        guard chmod(fixture.directory.path, 0o500) == 0 else { throw TestFailure(description: "Could not set store permissions") }
        try await rejects("Store publication failure aborts mutation after backup") { _ = try await engine.execute(self.start(), now: self.base) }
        _ = chmod(fixture.directory.path, 0o700)
        try check(try Data(contentsOf: fixture.url) == initial, "Atomic destination write failure leaves disk unchanged")
        try check(recordRows(try decoded(await engine.snapshot(now: base))).isEmpty, "Destination write failure leaves actor state unchanged")
        _ = try await engine.execute(start("故障恢复"), now: base)
        try check(recordRows(try decoded(await engine.snapshot(now: base))).count == 1, "Recovered storage accepts next mutation normally")
        var externallyChanged = try decoded(Data(contentsOf: fixture.url)); externallyChanged["revision"] = 900
        let externalBytes = try encoded(externallyChanged)
        try externalBytes.write(to: fixture.url)
        try await rejects("External edit detected before mutation") { _ = try await engine.execute(self.start("不能覆盖"), now: self.date(1)) }
        try await rejects("External edit detected before export") { _ = try await engine.exportBackup() }
        try check(try Data(contentsOf: fixture.url) == externalBytes, "External file data is never overwritten by stale actor")
        try check(recordRows(try decoded(await engine.snapshot(now: date(1)))).count == 1, "External edit rejection does not partially apply actor mutation")

        let corrupt = try Fixture(), corruptBytes = Data("{broken-json".utf8)
        try corruptBytes.write(to: corrupt.url)
        try await rejects("Corrupt startup refuses overwrite") { _ = try StoreEngine(url: corrupt.url) }
        try check(try Data(contentsOf: corrupt.url) == corruptBytes, "Corrupt store bytes retained for recovery")
        let linked = try Fixture(), destination = linked.directory.appendingPathComponent("actual.json")
        try initial.write(to: destination)
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: destination)
        try await rejects("Symlink store refused") { _ = try StoreEngine(url: linked.url) }
        try check(try Data(contentsOf: destination) == initial, "Symlink destination remains unchanged")
        let lockLink = try Fixture(), actualLock = lockLink.directory.appendingPathComponent("actual.lock")
        try Data().write(to: actualLock)
        try FileManager.default.createSymbolicLink(at: lockLink.url.appendingPathExtension("lock"), withDestinationURL: actualLock)
        try await rejects("Symlink lock file refused") { _ = try StoreEngine(url: lockLink.url) }
        let folder = try Fixture()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try await rejects("Store path occupied by folder refused") { _ = try StoreEngine(url: folder.url) }
    }

    func backupRetention() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        _ = try await engine.execute(start("备份"), now: base)
        let backupDirectory = fixture.directory.appendingPathComponent("Backups")
        let userFile = backupDirectory.appendingPathComponent("my-important-file.json")
        try Data("Keep me".utf8).write(to: userFile)
        for index in 0..<23 {
            _ = try await engine.execute(command("todoAdd", ["day": "2026-10-24", "title": "备份测试 \(index)"]), now: date(Double(index)))
        }
        let all = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        let backups = all.filter { $0.lastPathComponent.hasPrefix("store-r") }
        try check(backups.count == 20 && FileManager.default.fileExists(atPath: userFile.path), "Retention keeps 20 app backups and never removes unrelated files; found \(backups.count) backups")
        for backup in backups {
            _ = try StoreEngine.validateBackup(Data(contentsOf: backup), now: date(100))
            checks += 1
        }
        let temporary = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter { $0.hasPrefix(".time-note-") }
        try check(temporary.isEmpty, "Successful commits leave no temporary files")
    }

    func javascriptRevisionBoundaries() async throws {
        let fixture = try Fixture(), engine = try StoreEngine(url: fixture.url)
        let max: Int64 = 9_007_199_254_740_991
        var nearLimit = try decoded(await engine.exportBackup())
        nearLimit["revision"] = max - 2
        let imported = try decoded(await engine.importBackup(encoded(nearLimit), now: base))
        try check(number(imported, "revision") == Double(max - 1), "Near-limit import preserves exact JavaScript revision")
        let lastSafe = try decoded(await engine.execute(start("安全整数最后一次提交"), now: base))
        try check(number(lastSafe, "revision") == Double(max), "Last safe integer revision is represented exactly")
        let oldDisk = try Data(contentsOf: fixture.url)
        try await rejects("Next revision cannot round to previous JS Number") { _ = try await engine.execute(self.start("不能溢出"), now: self.date(1)) }
        try check(try Data(contentsOf: fixture.url) == oldDisk, "Revision exhaustion does not mutate disk")
        var invalidTarget = target(row(lastSafe)); invalidTarget["expectedRevision"] = max + 1
        let payload = try command("finish", invalidTarget)
        try await rejects("Unsafe expected revision rejected at command boundary") { _ = try await engine.execute(payload, now: self.date(1)) }
        let after = try decoded(await engine.snapshot(now: date(1)))
        try check(recordRows(after).count == 1 && number(after, "revision") == Double(max), "Revision overflow rejection leaves actor and bridge consistent")
    }

    func run() async throws {
        let groups: [(String, () async throws -> Void)] = [
            ("empty state and independent timers", emptyAndIndependentTimers),
            ("persistence and process locks", persistenceAndLocks),
            ("idempotency and optimistic concurrency", idempotencyAndCAS),
            ("simultaneous actor commands", simultaneousCommands),
            ("editing and exact time semantics", editTimeSemantics),
            ("original deadline races", originalDeadlineRaces),
            ("default categories, title memory and manual entries", categoryMemoryAndManual),
            ("editable labels, migration, deletion and backup", editableCategories),
            ("todos and strict command validation", todosAndInputValidation),
            ("Todo midnight rollover and cold restart", todoRollover),
            ("backup imports and malformed input atomicity", importsAndAtomicValidation),
            ("filesystem failures and recovery", fileFailuresAndRecovery),
            ("backup retention", backupRetention),
            ("JavaScript revision precision boundaries", javascriptRevisionBoundaries)
        ]
        for (name, test) in groups {
            let before = checks
            try await test()
            print("PASS \(name) (\(checks - before) checks)")
        }
        print("STORE ENGINE: \(checks) checks passed; all data isolated in temporary directories.")
    }
}

@main
private enum StoreTestMain {
    @MainActor static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-lock" {
            do {
                let engine = try StoreEngine(url: URL(fileURLWithPath: CommandLine.arguments[2]))
                _ = try await engine.snapshot()
                exit(0)
            } catch StoreEngineError.locked { exit(73) }
            catch { print("Unexpected lock probe failure: \(error)"); exit(74) }
        }
        do { try await StoreTests().run() }
        catch { FileHandle.standardError.write(Data("STORE TEST FAILURE: \(error)\n".utf8)); exit(1) }
    }
}
