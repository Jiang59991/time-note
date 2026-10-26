import Foundation

@main
struct NativeTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ title: String) {
            guard value() else { fatalError("Failed: \(title)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let first: [String: Any] = ["id": "record-a", "runID": "run-a", "mode": "pomodoro", "end": NSNull(), "deadline": ms + 60000, "revision": 2, "title": "科研"]
        var second = first; second["id"] = "record-b"; second["runID"] = "run-b"
        var snapshot: [String: Any] = ["records": [first, second]]
        let plans = NotificationPlanner.desired(snapshot, now: now)
        expect(plans.count == 2, "parallel timers each schedule")
        expect(Set(plans.map(\.identifier)).count == 2, "run IDs isolate requests")
        expect(plans == NotificationPlanner.desired(snapshot, now: now), "same snapshot has stable identifiers")
        var edited = first; edited["revision"] = 3
        expect(NotificationPlanner.desired(["records": [edited]], now: now).first!.identifier != plans.first!.identifier, "record edit changes request version")
        edited = first; edited["deadline"] = ms + 120000
        expect(NotificationPlanner.desired(["records": [edited]], now: now).first!.identifier != plans.first!.identifier, "deadline change replaces notification")
        var completed = first; completed["end"] = ms
        var expired = first; expired["deadline"] = ms
        var countup = first; countup["mode"] = "countup"
        expect(NotificationPlanner.desired(["records": [completed, expired, countup]], now: now).isEmpty, "finished expired and countup timers never schedule")
        expect(NotificationPlanner.desired(["records": []], now: now).isEmpty, "deletion removes desired notification")
        expect(NotificationPlanner.desired(snapshot, now: now.addingTimeInterval(90)).isEmpty, "relaunch after expiry does not notify again")
        let title = "=SUM(A1)\n\"quoted\", 中文 | test"
        snapshot = ["now": ms, "records": [["id": "record-export", "title": title, "category": "work", "start": ms - 60000, "end": ms, "mode": "countup"]], "todos": ["2026-10-24": [["id": "todo-export", "title": "@unsafe", "done": true]]]]
        let csv = String(data: ExportFormatter.csv(snapshot), encoding: .utf8)!
        expect(Array(ExportFormatter.csv(snapshot).prefix(3)) == [0xEF,0xBB,0xBF], "CSV Excel UTF8 BOM")
        expect(csv.contains("\"'=SUM(A1)\n\"\"quoted\"\", 中文 | test\""), "CSV formula neutralization quotes and newline")
        expect(csv.contains("\"'@unsafe\""), "Todo text formula neutralized")
        expect(csv.contains("\"1.00\""), "duration in minutes")
        expect(csv.contains("科研"), "stable Chinese category export")
        let markdown = String(data: ExportFormatter.markdown(snapshot), encoding: .utf8)!
        expect(markdown.contains("\\| test"), "Markdown table pipes escaped")
        expect(markdown.contains("- [x] @unsafe"), "Todo completion exported")
        expect(!markdown.contains("=SUM(A1)\n"), "Markdown multiline titles stay one table row")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dataFolder = fixture.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let alias = fixture.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dataFolder)
        expect(!ExportDestination.isAllowed(dataFolder.appendingPathComponent("store.json"), dataDirectory: dataFolder), "live store protected")
        expect(!ExportDestination.isAllowed(dataFolder.appendingPathComponent("Backups/new.json"), dataDirectory: dataFolder), "backup subtree protected")
        expect(!ExportDestination.isAllowed(alias.appendingPathComponent("new.json"), dataDirectory: dataFolder), "symlink into live tree protected")
        expect(ExportDestination.isAllowed(fixture.appendingPathComponent("Data-copy.json"), dataDirectory: dataFolder), "sibling export allowed")
        let diningSnapshot: [String: Any] = ["now": ms, "records": [["id": "meal", "title": "午餐", "category": "dining", "start": ms - 1800000, "end": ms, "mode": "countup"]], "todos": [:]]
        expect(String(data: ExportFormatter.csv(diningSnapshot), encoding: .utf8)!.contains("餐饮"), "Dining CSV label")
        expect(String(data: ExportFormatter.markdown(diningSnapshot), encoding: .utf8)!.contains("餐饮"), "Dining Markdown label")
        print("PASS \(checks) native planner/export checks")
    }
}
