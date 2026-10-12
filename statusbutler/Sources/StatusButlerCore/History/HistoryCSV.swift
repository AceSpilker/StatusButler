// E10·HS-04 事件日志导出 CSV（纯函数，无 IO —— 导出动作由调用方落盘）
// 转义遵循 RFC 4180 精神：字段含逗号/引号/换行时整体加引号，内部引号翻倍；行分隔用 \n（文本编辑器与 Numbers 均兼容）
public enum HistoryCSV {
    public static func eventsToCSV(_ rows: [HistoryEvent]) -> String {
        var lines = ["id,at,kind,detail"]
        for row in rows {
            let fields = [String(row.id), row.at, row.kind, row.detail ?? ""]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
