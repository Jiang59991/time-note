import Foundation
import CoreFoundation
import Darwin

// Darwin exposes both a `flock` structure and the BSD function with the same name.
@_silgen_name("flock")
private func timeNoteFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// The only writer of Time Note's canonical local data. All mutation work is synchronous
/// inside this actor: validation, revision checks, and the atomic file replacement never await.
actor StoreEngine {
    private let url: URL
    private let fileLock: StoreFileLock
    private var document: StoreDocument
    private var committedBytes: Data

    init(url: URL) throws {
        guard url.isFileURL else { throw StoreEngineError.validation("数据位置必须是本机文件。") }
        let resolved = url.standardizedFileURL
        let directory = resolved.deletingLastPathComponent()
        try StoreFiles.ensureDirectory(directory)
        let acquiredLock = try StoreFileLock(url: resolved.appendingPathExtension("lock"))
        let initial: StoreDocument
        let bytes: Data
        if try StoreFiles.exists(resolved) {
            bytes = try StoreFiles.read(resolved)
            do {
                initial = try StoreCodec.decodeDocument(bytes, validationNow: nil)
            } catch {
                throw StoreEngineError.corrupt("数据文件无法安全读取，原文件未改动。请从备份恢复。\n\(error.localizedDescription)")
            }
        } else {
            initial = StoreDocument.empty
            bytes = try StoreCodec.encodeDocument(initial)
            try StoreFiles.atomicWrite(bytes, to: resolved, replacing: false)
        }
        self.url = resolved
        self.fileLock = acquiredLock
        self.document = initial
        self.committedBytes = bytes
    }

    func snapshot(now: Date = Date()) throws -> Data {
        let nowMS = try StoreValidation.milliseconds(now)
        var next = document
        if try reconcile(&next, now: nowMS) {
            next.revision = try StoreValidation.increment(document.revision)
            try commit(next)
        }
        return try StoreCodec.encodeSnapshot(document, now: nowMS)
    }

    func execute(_ payload: Data, now: Date = Date()) throws -> Data {
        let nowMS = try StoreValidation.milliseconds(now)
        let parsed = try StoreCommand.parse(payload)

        if let prior = document.receipts.first(where: { $0.operationID == parsed.operationID }) {
            guard prior.canonicalPayload == parsed.canonicalPayload else {
                throw StoreEngineError.operationConflict
            }
            // A replay returns current truth, never an old snapshot that could roll back the UI.
            return try snapshot(now: now)
        }

        var next = document
        _ = try reconcile(&next, now: nowMS)

        // An expired timer cannot gain a new deadline just because its edit won a race with
        // the lifecycle reconciliation. Preserve the user's draft in the caller and refresh.
        if case let .edit(edit) = parsed.body,
           let original = document.records.first(where: { $0.id == edit.id }),
           original.end == nil, original.mode == .pomodoro,
           let deadline = original.deadline, deadline <= nowMS {
            try StoreValidation.validateEditFields(edit, now: nowMS)
            next.revision = try StoreValidation.increment(document.revision)
            try commit(next)
            throw StoreEngineError.conflict("这轮番茄已按原截止时间完成。请重新载入记录后再保存修改；你的输入可以保留。")
        }

        try apply(parsed.body, to: &next, original: document, now: nowMS)
        // Newly added / reopened historical Todos already received a revision in apply.
        _ = try carryForwardTodos(&next, now: nowMS, incrementRevisions: false)
        next.revision = try StoreValidation.increment(document.revision)
        next.receipts.append(OperationReceipt(
            operationID: parsed.operationID,
            canonicalPayload: parsed.canonicalPayload,
            committedRevision: next.revision,
            committedAt: nowMS
        ))
        // A bounded retry journal: current UI requests keep their IDs through retries.
        if next.receipts.count > StoreLimits.receiptCount {
            next.receipts.removeFirst(next.receipts.count - StoreLimits.receiptCount)
        }
        try StoreValidation.validate(next, now: nil)
        try commit(next)
        return try StoreCodec.encodeSnapshot(document, now: nowMS)
    }

    func exportBackup() throws -> Data {
        try verifyUnchangedFile()
        return try StoreCodec.encodeDocument(document)
    }

    /// Read-only preview validation for the native import confirmation sheet.
    nonisolated static func validateBackup(
        _ data: Data, now: Date = Date()
    ) throws -> (records: Int, todos: Int) {
        let nowMS = try StoreValidation.milliseconds(now)
        let decoded = try StoreCodec.decodeDocument(data, validationNow: nowMS)
        return (decoded.records.count, decoded.todos.values.reduce(0) { $0 + $1.count })
    }

    func importBackup(_ data: Data, now: Date = Date()) throws -> Data {
        let nowMS = try StoreValidation.milliseconds(now)
        var replacement = try StoreCodec.decodeDocument(data, validationNow: nowMS)
        _ = try reconcile(&replacement, now: nowMS)
        // The UI discards older snapshots. Imported data must advance the local revision too.
        replacement.revision = try StoreValidation.increment(max(document.revision, replacement.revision))
        try StoreValidation.validate(replacement, now: nil)
        try commit(replacement)
        return try StoreCodec.encodeSnapshot(document, now: nowMS)
    }

    private func reconcile(_ value: inout StoreDocument, now: Double) throws -> Bool {
        var changed = false
        for index in value.records.indices {
            if value.records[index].end == nil,
               value.records[index].mode == .pomodoro,
               let deadline = value.records[index].deadline, deadline <= now {
                value.records[index].end = deadline
                value.records[index].finishReason = "deadline"
                value.records[index].revision = try StoreValidation.increment(value.records[index].revision)
                changed = true
            }
        }
        let todosChanged = try carryForwardTodos(&value, now: now)
        return changed || todosChanged
    }

    private func carryForwardTodos(_ value: inout StoreDocument, now: Double, incrementRevisions: Bool = true) throws -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now / 1_000))
        let today = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        var carried: [StoreTodo] = []
        for day in value.todos.keys.filter({ $0 < today }).sorted() {
            let rows = value.todos[day]!
            for var todo in rows where !todo.done {
                if incrementRevisions { todo.revision = try StoreValidation.increment(todo.revision) }
                carried.append(todo)
            }
            let completed = rows.filter(\.done)
            if completed.isEmpty { value.todos.removeValue(forKey: day) }
            else { value.todos[day] = completed }
        }
        guard !carried.isEmpty else { return false }
        value.todos[today] = carried + (value.todos[today] ?? [])
        return true
    }

    private func apply(
        _ command: StoreCommand.Body, to value: inout StoreDocument,
        original: StoreDocument, now: Double
    ) throws {
        switch command {
        case let .start(input):
            let title = try StoreValidation.title(input.title, allowEmpty: true)
            let deadline = input.mode == .pomodoro
                ? try StoreValidation.deadline(start: now, minutes: input.minutes) : nil
            value.records.append(StoreRecord(
                id: UUID(), runID: UUID(), title: title,
                category: input.category, categoryManual: input.categoryManual,
                start: now, end: nil, mode: input.mode, minutes: input.minutes,
                deadline: deadline, revision: 1, finishReason: nil
            ))
            try remember(input.title, category: input.category, manual: input.categoryManual, in: &value)

        case let .manual(input):
            try StoreValidation.finishedInterval(start: input.start, end: input.end, now: now)
            let title = try StoreValidation.title(input.title, allowEmpty: true)
            value.records.append(StoreRecord(
                id: UUID(), runID: nil, title: title,
                category: input.category, categoryManual: input.categoryManual,
                start: input.start, end: input.end, mode: .countup, minutes: 25,
                deadline: nil, revision: 1, finishReason: "manual"
            ))
            try remember(input.title, category: input.category, manual: input.categoryManual, in: &value)

        case let .edit(input):
            try StoreValidation.validateEditFields(input, now: now)
            let originalRecord = try target(input.id, expected: input.expectedRevision, in: original)
            guard let index = value.records.firstIndex(where: { $0.id == input.id }) else {
                throw StoreEngineError.notFound("记录已不存在。")
            }
            var record = value.records[index]
            let title = try StoreValidation.title(input.title, allowEmpty: true)
            try StoreValidation.minutes(input.minutes, for: record.mode)
            let wasRunning = originalRecord.end == nil
            if wasRunning {
                let newDeadline = record.mode == .pomodoro
                    ? try StoreValidation.deadline(start: input.start, minutes: input.minutes) : nil
                switch input.intent {
                case .preserve:
                    guard input.end == nil else {
                        throw StoreEngineError.validation("填写结束时间后，请选择“保存并结束”。")
                    }
                    if let newDeadline, newDeadline <= now {
                        throw StoreEngineError.validation("修改后的番茄已经到点，请明确选择“按新截止时间结束”。")
                    }
                    record.end = nil
                    record.finishReason = nil
                case .finish:
                    guard let end = input.end else {
                        throw StoreEngineError.validation("保存并结束需要明确的结束时间。")
                    }
                    try StoreValidation.finishedInterval(start: input.start, end: end, now: now)
                    // An explicitly entered end describes actual history. Preserve it even
                    // when a start/duration correction moves the new goal into the past.
                    // The original-deadline race is rejected before entering this branch.
                    record.end = end
                    record.finishReason = newDeadline.map { end > $0 ? "corrected" : "manual" } ?? "manual"
                case .deadline:
                    guard let newDeadline, newDeadline <= now else {
                        throw StoreEngineError.validation("只有已到达的新番茄截止时间才能按到点结束。")
                    }
                    if let suppliedEnd = input.end, !StoreValidation.sameTime(suppliedEnd, newDeadline) {
                        throw StoreEngineError.validation("结束时间与预览的新截止时间不一致，请重新确认。")
                    }
                    record.end = newDeadline
                    record.finishReason = "deadline"
                }
                record.deadline = newDeadline
            } else {
                guard input.intent == .preserve, let end = input.end else {
                    throw StoreEngineError.validation("已结束记录只能修改历史，不能清空结束时间或重新开始。")
                }
                try StoreValidation.finishedInterval(start: input.start, end: end, now: now)
                record.end = end
                // Historical corrections describe actual time; never cap them to an old goal.
                if input.start != originalRecord.start || end != originalRecord.end || input.minutes != originalRecord.minutes {
                    record.finishReason = "corrected"
                }
            }
            record.title = title
            record.category = input.category
            record.categoryManual = input.categoryManual
            record.start = input.start
            record.minutes = input.minutes
            record.revision = try StoreValidation.increment(originalRecord.revision)
            value.records[index] = record
            try remember(input.title, category: input.category, manual: input.categoryManual, in: &value)

        case let .finish(input):
            let originalRecord = try target(input.id, expected: input.expectedRevision, in: original)
            guard originalRecord.runID != nil, originalRecord.end == nil else {
                throw StoreEngineError.conflict("这项计时已经结束，请重新载入最新记录。")
            }
            guard let index = value.records.firstIndex(where: { $0.id == input.id }) else {
                throw StoreEngineError.notFound("记录已不存在。")
            }
            if originalRecord.mode == .pomodoro, let deadline = originalRecord.deadline, deadline <= now {
                // Reconciliation already closed it at the scheduled time, irrespective of
                // a delayed button click or delayed notification delivery.
                break
            }
            let end = input.end ?? now
            try StoreValidation.timestamp(end)
            guard end <= now else { throw StoreEngineError.validation("结束时间不能在未来。") }
            guard end >= originalRecord.start else { throw StoreEngineError.validation("结束时间不能早于开始时间。") }
            if end == originalRecord.start {
                // A true zero-duration accidental start/stop has no interval to record.
                value.records.remove(at: index)
            } else {
                value.records[index].end = end
                value.records[index].finishReason = "manual"
                value.records[index].revision = try StoreValidation.increment(originalRecord.revision)
            }

        case let .delete(input):
            _ = try target(input.id, expected: input.expectedRevision, in: original)
            value.records.removeAll { $0.id == input.id }

        case let .todoAdd(day, title):
            try StoreValidation.day(day)
            let cleaned = try StoreValidation.title(title, allowEmpty: false)
            value.todos[day, default: []].append(StoreTodo(id: UUID(), title: cleaned, done: false, revision: 1))

        case let .todoSet(input, done):
            let index = try todoTarget(input, in: value)
            guard var rows = value.todos[input.day] else { throw StoreEngineError.notFound("待办已不存在。") }
            rows[index].done = done
            rows[index].revision = try StoreValidation.increment(rows[index].revision)
            value.todos[input.day] = rows

        case let .todoDelete(input):
            let index = try todoTarget(input, in: value)
            guard var rows = value.todos[input.day] else { throw StoreEngineError.notFound("待办已不存在。") }
            rows.remove(at: index)
            if rows.isEmpty { value.todos.removeValue(forKey: input.day) }
            else { value.todos[input.day] = rows }
        }
    }

    private func target(_ id: UUID, expected: Int64, in value: StoreDocument) throws -> StoreRecord {
        guard let record = value.records.first(where: { $0.id == id }) else {
            throw StoreEngineError.notFound("记录已不存在，可能已在其他操作中删除。")
        }
        guard record.revision == expected else {
            throw StoreEngineError.conflict("记录已更新，请重新载入后再修改；当前输入不会自动覆盖新数据。")
        }
        return record
    }

    private func todoTarget(_ input: StoreCommand.TodoTarget, in value: StoreDocument) throws -> Int {
        try StoreValidation.day(input.day)
        guard let rows = value.todos[input.day], let index = rows.firstIndex(where: { $0.id == input.id }) else {
            throw StoreEngineError.notFound("这条待办已不存在。")
        }
        guard rows[index].revision == input.expectedRevision else {
            throw StoreEngineError.conflict("待办已更新，请重新载入后再操作。")
        }
        return index
    }

    private func remember(_ title: String, category: String, manual: Bool, in value: inout StoreDocument) throws {
        let key = StoreValidation.normalizedTitle(title)
        if manual && !key.isEmpty {
            guard value.categoryMemory[key] != nil || value.categoryMemory.count < StoreLimits.memoryCount else {
                throw StoreEngineError.validation("分类记忆已达到容量限制，请先导出备份后整理。")
            }
            value.categoryMemory[key] = category
        }
    }

    private func verifyUnchangedFile() throws {
        let current = try StoreFiles.read(url)
        guard current == committedBytes else {
            throw StoreEngineError.io("数据文件被其他程序修改，已停止写入以保护内容。请退出后检查文件及备份。")
        }
    }

    private func commit(_ next: StoreDocument) throws {
        let bytes = try StoreCodec.encodeDocument(next)
        try verifyUnchangedFile()
        let backupDirectory = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try StoreFiles.ensureDirectory(backupDirectory, rejectSymlink: true)
        let revisionName = String(format: "%020lld", document.revision)
        let backup = backupDirectory.appendingPathComponent("store-r\(revisionName)-\(UUID().uuidString).json")
        // Backup failure is a failed mutation, not permission to overwrite the only copy.
        try StoreFiles.atomicWrite(committedBytes, to: backup, replacing: false)
        try StoreFiles.atomicWrite(bytes, to: url, replacing: true)
        // rename is the commit point; nothing below can throw and claim the old data survived.
        document = next
        committedBytes = bytes
        StoreFiles.pruneBackups(in: backupDirectory, keeping: StoreLimits.backupCount)
    }
}

private enum StoreLimits {
    static let schemaVersion = 1
    static let fileBytes = 64 * 1024 * 1024
    static let commandBytes = 128 * 1024
    static let recordCount = 100_000
    static let todoCount = 100_000
    static let memoryCount = 10_000
    static let receiptCount = 4_096
    static let backupCount = 20
    // The WKWebView bridge represents revisions as JavaScript Number. Never emit a
    // revision for which +1 or an optimistic-concurrency comparison loses precision.
    static let maximumRevision: Int64 = 9_007_199_254_740_991
    static let categories: Set<String> = ["work", "create", "move", "rest", "sleep", "dining", "life", "other"]
}

enum StoreEngineError: LocalizedError {
    case validation(String)
    case corrupt(String)
    case unsupportedSchema
    case locked
    case io(String)
    case conflict(String)
    case operationConflict
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case let .validation(message), let .corrupt(message), let .io(message),
             let .conflict(message), let .notFound(message): return message
        case .unsupportedSchema: return "备份或数据文件的版本不受当前应用支持，文件未改动。"
        case .locked: return "此数据文件正由另一个时间便签进程使用。请先退出另一份应用，避免同时写入。"
        case .operationConflict: return "同一个操作编号对应了不同内容，已拒绝写入。请重新发起该操作。"
        }
    }
}

private enum RecordMode: String, Codable { case countup, pomodoro }

private struct StoreRecord: Codable {
    var id: UUID
    var runID: UUID?
    var title: String
    var category: String
    var categoryManual: Bool
    var start: Double
    var end: Double?
    var mode: RecordMode
    var minutes: Int
    var deadline: Double?
    var revision: Int64
    var finishReason: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, runID, title, category, categoryManual, start, end, mode, minutes, deadline, revision, finishReason
    }

    // Synthesized Codable would omit nil values. The bridge explicitly requires JSON null.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(runID, forKey: .runID)
        try container.encode(title, forKey: .title)
        try container.encode(category, forKey: .category)
        try container.encode(categoryManual, forKey: .categoryManual)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(mode, forKey: .mode)
        try container.encode(minutes, forKey: .minutes)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(revision, forKey: .revision)
        try container.encode(finishReason, forKey: .finishReason)
    }
}

private struct StoreTodo: Codable {
    var id: UUID
    var title: String
    var done: Bool
    var revision: Int64
}

private struct OperationReceipt: Codable {
    var operationID: UUID
    var canonicalPayload: String
    var committedRevision: Int64
    var committedAt: Double
}

private struct StoreDocument: Codable {
    var schemaVersion: Int
    var revision: Int64
    var records: [StoreRecord]
    var todos: [String: [StoreTodo]]
    var categoryMemory: [String: String]
    var receipts: [OperationReceipt]

    static var empty: StoreDocument {
        StoreDocument(schemaVersion: StoreLimits.schemaVersion, revision: 0,
                      records: [], todos: [:], categoryMemory: [:], receipts: [])
    }
}

private struct StoreSnapshot: Encodable {
    let schemaVersion: Int
    let revision: Int64
    let records: [StoreRecord]
    let todos: [String: [StoreTodo]]
    let categoryMemory: [String: String]
    let now: Double
}

private enum StoreCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encodeDocument(_ value: StoreDocument) throws -> Data {
        let bytes = try encoder().encode(value)
        guard bytes.count <= StoreLimits.fileBytes else {
            throw StoreEngineError.validation("数据文件超过安全容量，请先导出并整理记录。")
        }
        return bytes
    }

    static func encodeSnapshot(_ value: StoreDocument, now: Double) throws -> Data {
        try encoder().encode(StoreSnapshot(schemaVersion: value.schemaVersion, revision: value.revision,
                                          records: value.records, todos: value.todos,
                                          categoryMemory: value.categoryMemory, now: now))
    }

    static func decodeDocument(_ data: Data, validationNow: Double?) throws -> StoreDocument {
        guard !data.isEmpty, data.count <= StoreLimits.fileBytes else {
            throw StoreEngineError.validation("备份为空或超过 64 MB，无法安全导入。")
        }
        let object = try StoreJSON.object(data)
        try StoreJSON.keys(object, required: ["schemaVersion", "revision", "records", "todos", "categoryMemory", "receipts"])
        guard try StoreJSON.integer(object, "schemaVersion") == StoreLimits.schemaVersion else {
            throw StoreEngineError.unsupportedSchema
        }
        guard let records = object["records"] as? [[String: Any]], records.count <= StoreLimits.recordCount,
              let todos = object["todos"] as? [String: Any],
              let receipts = object["receipts"] as? [[String: Any]], receipts.count <= StoreLimits.receiptCount,
              let memory = object["categoryMemory"] as? [String: Any], memory.count <= StoreLimits.memoryCount else {
            throw StoreEngineError.validation("备份中的记录、待办、分类记忆或操作回执格式无效。")
        }
        for record in records {
            try StoreJSON.keys(record, required: Set(StoreRecord.CodingKeys.allCases.map(\.rawValue)))
        }
        var todoCount = 0
        for (_, rawRows) in todos {
            guard let rows = rawRows as? [[String: Any]] else { throw StoreEngineError.validation("待办日期分组格式无效。") }
            todoCount += rows.count
            guard todoCount <= StoreLimits.todoCount else { throw StoreEngineError.validation("待办数量超过安全容量。") }
            for row in rows { try StoreJSON.keys(row, required: ["id", "title", "done", "revision"]) }
        }
        for receipt in receipts {
            try StoreJSON.keys(receipt, required: ["operationID", "canonicalPayload", "committedRevision", "committedAt"])
        }
        let decoded: StoreDocument
        do { decoded = try JSONDecoder().decode(StoreDocument.self, from: data) }
        catch { throw StoreEngineError.validation("备份字段类型不正确，无法读取。") }
        try StoreValidation.validate(decoded, now: validationNow)
        return decoded
    }
}

private enum StoreValidation {
    private static let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    static func normalizedTitle(_ input: String) -> String {
        input.trimmingCharacters(in: trimSet).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func title(_ input: String, allowEmpty: Bool) throws -> String {
        let cleaned = input.trimmingCharacters(in: trimSet).precomposedStringWithCanonicalMapping
        guard cleaned.count <= 500, !cleaned.contains("\u{0000}") else {
            throw StoreEngineError.validation("标题最多 500 个字符，且不能包含空字符。")
        }
        if cleaned.isEmpty {
            guard allowEmpty else { throw StoreEngineError.validation("请填写待办内容。") }
            return "未命名事项"
        }
        return cleaned
    }

    static func timestamp(_ value: Double) throws {
        guard value.isFinite, value >= -62_135_596_800_000, value <= 253_402_300_799_999 else {
            throw StoreEngineError.validation("时间格式无效或超出支持范围。")
        }
    }

    static func milliseconds(_ date: Date) throws -> Double {
        let value = date.timeIntervalSince1970 * 1_000
        try timestamp(value)
        return value
    }

    static func sameTime(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

    static func increment(_ value: Int64) throws -> Int64 {
        guard value >= 0, value < StoreLimits.maximumRevision else { throw StoreEngineError.validation("数据修订号无效或已超出安全范围。") }
        return value + 1
    }

    static func minutes(_ value: Int, for mode: RecordMode) throws {
        guard (mode == .pomodoro ? 1...240 : 0...240).contains(value) else {
            throw StoreEngineError.validation("番茄时长需为 1—240 分钟；普通计时设置也不能超出范围。")
        }
    }

    static func deadline(start: Double, minutes: Int) throws -> Double {
        try self.minutes(minutes, for: .pomodoro)
        let end = start + Double(minutes) * 60_000
        try timestamp(end)
        return end
    }

    static func category(_ value: String) throws {
        guard StoreLimits.categories.contains(value) else {
            throw StoreEngineError.validation("分类无效，只能选择科研、自媒体、运动、娱乐、睡眠、餐饮、杂事或其他。")
        }
    }

    static func finishedInterval(start: Double, end: Double, now: Double) throws {
        try timestamp(start)
        try timestamp(end)
        guard end > start else { throw StoreEngineError.validation("结束时间必须晚于开始时间。") }
        guard end <= now else { throw StoreEngineError.validation("已完成记录的结束时间不能在未来。") }
    }

    static func day(_ key: String) throws {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              key.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), (1...9999).contains(year) else {
            throw StoreEngineError.validation("待办日期必须使用有效的 YYYY-MM-DD 格式。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw StoreEngineError.validation("待办日期不存在，请检查年月日。")
        }
    }

    static func validateEditFields(_ input: StoreCommand.Edit, now: Double) throws {
        _ = try title(input.title, allowEmpty: true)
        try category(input.category)
        try timestamp(input.start)
        guard input.start <= now else { throw StoreEngineError.validation("开始时间不能在未来。") }
        if let end = input.end { try finishedInterval(start: input.start, end: end, now: now) }
    }

    static func validate(_ value: StoreDocument, now: Double?) throws {
        guard value.schemaVersion == StoreLimits.schemaVersion else { throw StoreEngineError.unsupportedSchema }
        guard value.revision >= 0, value.revision <= StoreLimits.maximumRevision,
              value.records.count <= StoreLimits.recordCount,
              value.categoryMemory.count <= StoreLimits.memoryCount,
              value.receipts.count <= StoreLimits.receiptCount else {
            throw StoreEngineError.validation("数据版本、修订号或数量无效。")
        }
        var ids = Set<UUID>()
        for record in value.records {
            guard ids.insert(record.id).inserted else { throw StoreEngineError.validation("备份中存在重复的记录编号。") }
            if let runID = record.runID {
                guard ids.insert(runID).inserted else { throw StoreEngineError.validation("计时编号重复，无法确定记录所属任务。") }
            }
            _ = try title(record.title, allowEmpty: false)
            try category(record.category)
            try timestamp(record.start)
            try minutes(record.minutes, for: record.mode)
            guard record.revision >= 0, record.revision <= value.revision else {
                throw StoreEngineError.validation("记录修订号与备份不一致。")
            }
            if let now, record.start > now { throw StoreEngineError.validation("备份包含未来开始的记录。") }
            if let end = record.end {
                try timestamp(end)
                guard end > record.start else { throw StoreEngineError.validation("备份包含结束不晚于开始的记录。") }
                if let now, end > now { throw StoreEngineError.validation("备份包含未来结束的记录。") }
                guard let reason = record.finishReason, ["manual", "deadline", "corrected"].contains(reason) else {
                    throw StoreEngineError.validation("已结束记录缺少有效结束原因。")
                }
            } else {
                guard record.runID != nil, record.finishReason == nil else {
                    throw StoreEngineError.validation("开放记录必须关联计时任务，且不能已有结束原因。")
                }
            }
            switch record.mode {
            case .countup:
                guard record.deadline == nil, record.finishReason != "deadline" else {
                    throw StoreEngineError.validation("普通计时不能拥有番茄截止时间。")
                }
            case .pomodoro:
                guard record.runID != nil, let deadline = record.deadline else {
                    throw StoreEngineError.validation("番茄记录缺少计时编号或截止时间。")
                }
                try timestamp(deadline)
                if record.end == nil {
                    let expected = try self.deadline(start: record.start, minutes: record.minutes)
                    guard sameTime(deadline, expected) else { throw StoreEngineError.validation("运行中番茄截止时间与开始及目标时长不一致。") }
                }
                if record.finishReason == "deadline" {
                    guard let end = record.end, sameTime(end, deadline) else { throw StoreEngineError.validation("到点完成的结束时间与截止时间不一致。") }
                }
                if record.finishReason == "manual", let end = record.end, end > deadline {
                    throw StoreEngineError.validation("手动提前结束的番茄不能超过原截止时间。")
                }
            }
            if record.runID == nil {
                guard record.end != nil, record.mode == .countup else { throw StoreEngineError.validation("手动补记必须是已结束的普通记录。") }
            }
        }
        var todoCount = 0
        for (key, rows) in value.todos {
            try day(key)
            todoCount += rows.count
            guard todoCount <= StoreLimits.todoCount else { throw StoreEngineError.validation("待办数量超过安全容量。") }
            for row in rows {
                guard ids.insert(row.id).inserted else { throw StoreEngineError.validation("备份中存在重复的待办或记录编号。") }
                _ = try title(row.title, allowEmpty: false)
                guard row.revision >= 0, row.revision <= value.revision else { throw StoreEngineError.validation("待办修订号无效。") }
            }
        }
        for (title, category) in value.categoryMemory {
            guard !title.isEmpty, title == normalizedTitle(title), title.count <= 500, !title.contains("\u{0000}") else {
                throw StoreEngineError.validation("分类记忆的标题键格式无效。")
            }
            try self.category(category)
        }
        var operationIDs = Set<UUID>()
        var lastRevision: Int64 = -1
        for receipt in value.receipts {
            guard operationIDs.insert(receipt.operationID).inserted,
                  receipt.committedRevision > lastRevision,
                  receipt.committedRevision > 0, receipt.committedRevision <= value.revision else {
                throw StoreEngineError.validation("操作回执编号重复或修订顺序无效。")
            }
            try timestamp(receipt.committedAt)
            guard let bytes = receipt.canonicalPayload.data(using: .utf8) else { throw StoreEngineError.validation("操作回执编码无效。") }
            let command = try StoreCommand.parse(bytes)
            guard command.operationID == receipt.operationID, command.canonicalPayload == receipt.canonicalPayload else {
                throw StoreEngineError.validation("操作回执与其原始命令不一致。")
            }
            lastRevision = receipt.committedRevision
        }
    }
}

private struct StoreCommand {
    enum CompletionIntent: String { case preserve, finish, deadline }
    struct Start { let title: String; let category: String; let categoryManual: Bool; let mode: RecordMode; let minutes: Int }
    struct Manual { let title: String; let category: String; let categoryManual: Bool; let start: Double; let end: Double }
    struct Edit { let id: UUID; let expectedRevision: Int64; let title: String; let category: String; let categoryManual: Bool; let start: Double; let end: Double?; let minutes: Int; let intent: CompletionIntent }
    struct Target { let id: UUID; let expectedRevision: Int64 }
    struct Finish { let id: UUID; let expectedRevision: Int64; let end: Double? }
    struct TodoTarget { let day: String; let id: UUID; let expectedRevision: Int64 }
    enum Body {
        case start(Start), manual(Manual), edit(Edit), finish(Finish), delete(Target)
        case todoAdd(day: String, title: String), todoSet(TodoTarget, done: Bool), todoDelete(TodoTarget)
    }
    let operationID: UUID
    let canonicalPayload: String
    let body: Body

    static func parse(_ data: Data) throws -> StoreCommand {
        guard !data.isEmpty, data.count <= StoreLimits.commandBytes else { throw StoreEngineError.validation("操作内容为空或过大。") }
        let object = try StoreJSON.object(data)
        let operationID = try StoreJSON.uuid(object, "operationID")
        let type = try StoreJSON.string(object, "type")
        let base: Set<String> = ["operationID", "type"]
        let body: Body
        switch type {
        case "start":
            try StoreJSON.keys(object, required: base.union(["title", "category", "categoryManual", "mode", "minutes"]))
            guard let mode = RecordMode(rawValue: try StoreJSON.string(object, "mode")) else { throw StoreEngineError.validation("计时模式无效。") }
            let minutes = Int(try StoreJSON.integer(object, "minutes", maximum: 240))
            try StoreValidation.minutes(minutes, for: mode)
            body = .start(Start(title: try StoreJSON.string(object, "title"), category: try StoreJSON.category(object),
                                categoryManual: try StoreJSON.bool(object, "categoryManual"), mode: mode, minutes: minutes))
        case "manual":
            try StoreJSON.keys(object, required: base.union(["title", "category", "categoryManual", "start", "end"]))
            body = .manual(Manual(title: try StoreJSON.string(object, "title"), category: try StoreJSON.category(object),
                                  categoryManual: try StoreJSON.bool(object, "categoryManual"),
                                  start: try StoreJSON.number(object, "start"), end: try StoreJSON.number(object, "end")))
        case "edit":
            try StoreJSON.keys(object, required: base.union(["id", "expectedRevision", "title", "category", "categoryManual", "start", "end", "minutes", "completionIntent"]))
            guard let intent = CompletionIntent(rawValue: try StoreJSON.string(object, "completionIntent")) else { throw StoreEngineError.validation("结束确认方式无效。") }
            body = .edit(Edit(id: try StoreJSON.uuid(object, "id"), expectedRevision: try StoreJSON.integer(object, "expectedRevision"),
                              title: try StoreJSON.string(object, "title"), category: try StoreJSON.category(object),
                              categoryManual: try StoreJSON.bool(object, "categoryManual"), start: try StoreJSON.number(object, "start"),
                              end: try StoreJSON.optionalNumber(object, "end"), minutes: Int(try StoreJSON.integer(object, "minutes", maximum: 240)), intent: intent))
        case "finish":
            try StoreJSON.keys(object, required: base.union(["id", "expectedRevision"]), optional: ["end"])
            body = .finish(Finish(id: try StoreJSON.uuid(object, "id"), expectedRevision: try StoreJSON.integer(object, "expectedRevision"),
                                  end: object["end"] == nil ? nil : try StoreJSON.optionalNumber(object, "end")))
        case "delete":
            try StoreJSON.keys(object, required: base.union(["id", "expectedRevision"]))
            body = .delete(Target(id: try StoreJSON.uuid(object, "id"), expectedRevision: try StoreJSON.integer(object, "expectedRevision")))
        case "todoAdd":
            try StoreJSON.keys(object, required: base.union(["day", "title"]))
            body = .todoAdd(day: try StoreJSON.string(object, "day"), title: try StoreJSON.string(object, "title"))
        case "todoSet", "todoDelete":
            try StoreJSON.keys(object, required: base.union(type == "todoSet" ? ["day", "id", "expectedRevision", "done"] : ["day", "id", "expectedRevision"]))
            let target = TodoTarget(day: try StoreJSON.string(object, "day"), id: try StoreJSON.uuid(object, "id"),
                                    expectedRevision: try StoreJSON.integer(object, "expectedRevision"))
            body = type == "todoSet" ? .todoSet(target, done: try StoreJSON.bool(object, "done")) : .todoDelete(target)
        default: throw StoreEngineError.validation("不支持的记录操作。")
        }
        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let canonical = String(data: canonicalData, encoding: .utf8) else { throw StoreEngineError.validation("操作内容编码无效。") }
        return StoreCommand(operationID: operationID, canonicalPayload: canonical, body: body)
    }
}

private enum StoreJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StoreEngineError.validation("数据必须是 JSON 对象。")
            }
            return object
        } catch let error as StoreEngineError { throw error }
        catch { throw StoreEngineError.validation("JSON 数据无法解析。") }
    }

    static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw StoreEngineError.validation("数据字段缺失或包含不支持的字段，请使用此版本的完整备份或操作。")
        }
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw StoreEngineError.validation("字段 \(key) 必须是文本。") }
        return value
    }

    static func uuid(_ object: [String: Any], _ key: String) throws -> UUID {
        guard let uuid = UUID(uuidString: try string(object, key)) else { throw StoreEngineError.validation("字段 \(key) 的编号格式无效。") }
        return uuid
    }

    static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw StoreEngineError.validation("字段 \(key) 必须是真或假。")
        }
        return value.boolValue
    }

    static func number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw StoreEngineError.validation("字段 \(key) 必须是有效数字。")
        }
        return value.doubleValue
    }

    static func optionalNumber(_ object: [String: Any], _ key: String) throws -> Double? {
        if object[key] is NSNull { return nil }
        return try number(object, key)
    }

    static func integer(_ object: [String: Any], _ key: String, maximum: Int64 = StoreLimits.maximumRevision) throws -> Int64 {
        _ = try number(object, key)
        let value = object[key] as! NSNumber
        var decimal = value.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        guard decimal == rounded, decimal >= 0, decimal <= Decimal(maximum) else {
            throw StoreEngineError.validation("字段 \(key) 必须是有效的非负整数。")
        }
        return NSDecimalNumber(decimal: decimal).int64Value
    }

    static func category(_ object: [String: Any]) throws -> String {
        let result = try string(object, "category")
        try StoreValidation.category(result)
        return result
    }
}

private final class StoreFileLock: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreFiles.posixError("无法打开数据锁") }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            Darwin.close(fd)
            throw StoreEngineError.io("数据锁不是正常文件，已停止读取。")
        }
        guard timeNoteFileLock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw StoreEngineError.locked }
            throw StoreFiles.posixError("无法锁定数据文件", code: code)
        }
        descriptor = fd
    }

    deinit {
        _ = timeNoteFileLock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

private enum StoreFiles {
    static func posixError(_ context: String, code: Int32 = errno) -> StoreEngineError {
        .io("\(context)：\(String(cString: strerror(code)))。数据未确认保存，请检查磁盘空间和访问权限。")
    }

    static func ensureDirectory(_ url: URL, rejectSymlink: Bool = false) throws {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK), !rejectSymlink {
                var followed = stat()
                let directoryFD = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
                guard directoryFD >= 0 else { throw posixError("无法访问数据目录") }
                defer { Darwin.close(directoryFD) }
                guard Darwin.fstat(directoryFD, &followed) == 0, (followed.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    throw StoreEngineError.io("数据目录不是可用文件夹。")
                }
                return
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw StoreEngineError.io("数据或备份目录被文件占用，无法安全保存。") }
            return
        }
        guard errno == ENOENT else { throw posixError("无法访问数据目录") }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw StoreEngineError.io("无法创建数据目录：\(error.localizedDescription)") }
    }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw StoreEngineError.io("数据文件不是普通文件，不能覆盖。") }
            return true
        }
        if errno == ENOENT { return false }
        throw posixError("无法检查数据文件")
    }

    static func read(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError("无法读取数据文件") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= StoreLimits.fileBytes else {
            throw StoreEngineError.io("数据文件为空、不是普通文件或超过 64 MB；原文件未改动。")
        }
        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("读取数据文件失败")
            }
            guard result.count + count <= StoreLimits.fileBytes else { throw StoreEngineError.io("数据文件在读取时超出安全容量。") }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard !result.isEmpty else { throw StoreEngineError.io("数据文件为空，原文件未改动。") }
        return result
    }

    static func atomicWrite(_ data: Data, to destination: URL, replacing: Bool) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".time-note-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("无法创建临时数据文件") }
        var stillOpen = true
        defer {
            if stillOpen { Darwin.close(descriptor) }
            _ = Darwin.unlink(temporary.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("写入临时数据失败")
                }
                guard count > 0 else { throw StoreEngineError.io("磁盘未写入数据，原文件保持不变。") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("同步临时数据失败") }
        if Darwin.close(descriptor) != 0 {
            stillOpen = false
            throw posixError("关闭临时数据失败")
        }
        stillOpen = false
        if replacing {
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixError("原子替换数据失败") }
        } else {
            // An exclusive hard link publishes a new, fully written file without clobbering
            // a file unexpectedly created by another process at this path.
            guard Darwin.link(temporary.path, destination.path) == 0 else { throw posixError("创建完整数据文件失败") }
            _ = Darwin.unlink(temporary.path)
        }
        // rename/link above is the commit point. Directory fsync is best-effort because some
        // filesystems reject it; never throw after commit and falsely claim the old file survived.
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 { _ = Darwin.fsync(directoryFD); _ = Darwin.close(directoryFD) }
    }

    static func pruneBackups(in directory: URL, keeping count: Int) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let owned = urls.filter {
            $0.lastPathComponent.range(of: #"^store-r[0-9]{20}-[0-9A-F-]{36}\.json$"#, options: .regularExpression) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if owned.count > count {
            for url in owned.prefix(owned.count - count) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
