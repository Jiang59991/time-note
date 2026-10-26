import Foundation

enum ExportFormatter {
    static let categories = ["work": "科研", "create": "自媒体", "move": "运动", "rest": "娱乐", "sleep": "睡眠", "dining": "餐饮", "life": "杂事", "other": "其他"]
    static func csv(_ snapshot: [String: Any]) -> Data {
        var rows = [["类型", "ID", "事项", "分类", "开始时间", "结束时间", "分钟", "模式", "Todo 日期", "Todo 完成"]]
        let now = snapshot["now"] as? Double ?? Date().timeIntervalSince1970 * 1000
        for record in snapshot["records"] as? [[String: Any]] ?? [] {
            let start = record["start"] as? Double ?? now
            let end = record["end"] as? Double
            let effectiveEnd = end ?? min(now, record["deadline"] as? Double ?? now)
            rows.append(["时间记录", record["id"] as? String ?? "", record["title"] as? String ?? "",
                categories[record["category"] as? String ?? ""] ?? "其他", iso(start), end.map(iso) ?? "进行中",
                String(format: "%.2f", max(0, effectiveEnd - start) / 60000), record["mode"] as? String ?? "", "", ""])
        }
        for (day, todos) in (snapshot["todos"] as? [String: [[String: Any]]] ?? [:]).sorted(by: { $0.key < $1.key }) {
            for todo in todos {
                rows.append(["Todo", todo["id"] as? String ?? "", todo["title"] as? String ?? "", "", "", "", "", "", day,
                    (todo["done"] as? Bool ?? false) ? "是" : "否"])
            }
        }
        return Data(("\u{FEFF}" + rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
    static func markdown(_ snapshot: [String: Any]) -> Data {
        var lines = ["# Time Note 导出", "", "导出时间：\(iso(Date().timeIntervalSince1970 * 1000))", "", "## 时间记录", "", "| 事项 | 分类 | 开始 | 结束 | 模式 |", "| --- | --- | --- | --- | --- |"]
        for record in snapshot["records"] as? [[String: Any]] ?? [] {
            lines.append("| \(md(record["title"] as? String ?? "")) | \(categories[record["category"] as? String ?? ""] ?? "其他") | \(iso(record["start"] as? Double ?? 0)) | \((record["end"] as? Double).map(iso) ?? "进行中") | \(record["mode"] as? String == "pomodoro" ? "番茄" : "正计时") |")
        }
        lines += ["", "## Todo"]
        for (day, todos) in (snapshot["todos"] as? [String: [[String: Any]]] ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines += ["", "### \(day)", ""]
            for todo in todos { lines.append("- [\((todo["done"] as? Bool ?? false) ? "x" : " ")] \(md(todo["title"] as? String ?? ""))") }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    private static func iso(_ ms: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
    private static func md(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        for character in ["\\", "|", "`", "*", "_", "[", "]"] { text = text.replacingOccurrences(of: character, with: "\\" + character) }
        return text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func csvCell(_ value: String) -> String {
        // Formula-looking user text stays text when opened by spreadsheet applications.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { trimmed.hasPrefix($0) || value.hasPrefix($0) }) ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
