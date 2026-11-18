import Foundation

/// RFC 4180 CSV helpers.
public enum CSV {
    public static func escape(_ field: String) -> String {
        // Neutralize spreadsheet formula injection (=, +, -, @ at start).
        var f = field
        if let c = f.first, "=+-@".contains(c), Double(f) == nil { f = "'" + f }
        if f.contains(",") || f.contains("\"") || f.contains("\n") || f.contains("\r") {
            return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return f
    }

    public static func row(_ fields: [String]) -> String { fields.map(escape).joined(separator: ",") }

    public static func document(header: [String], rows: [[String]]) -> String {
        ([row(header)] + rows.map(row)).joined(separator: "\r\n") + "\r\n"
    }

    public static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var inQuotes = false
        var it = Array(line)
        var i = 0
        while i < it.count {
            let c = it[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 } else { inQuotes = false }
                } else { cur.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { fields.append(cur); cur = "" }
                else { cur.append(c) }
            }
            i += 1
        }
        fields.append(cur)
        it.removeAll()
        return fields
    }
}
