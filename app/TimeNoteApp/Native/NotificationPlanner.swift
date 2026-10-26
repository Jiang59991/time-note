import Foundation

struct PlannedNotification: Equatable {
    let identifier: String
    let title: String
    let recordID: String
    let deadline: Double
}

enum NotificationPlanner {
    static func desired(_ snapshot: [String: Any], now: Date = Date()) -> [PlannedNotification] {
        let milliseconds = now.timeIntervalSince1970 * 1000
        return (snapshot["records"] as? [[String: Any]] ?? []).compactMap { record in
            guard record["end"] is NSNull, record["mode"] as? String == "pomodoro",
                  let runID = record["runID"] as? String,
                  let deadline = record["deadline"] as? Double, deadline.isFinite, deadline > milliseconds, deadline < Double(Int64.max) else { return nil }
            let version = record["revision"] as? Int ?? 0
            return PlannedNotification(identifier: "time-note.\(runID).\(version).\(Int64(deadline))",
                title: record["title"] as? String ?? "计时完成", recordID: record["id"] as? String ?? "", deadline: deadline)
        }
    }
}
