import Foundation
import SQLite3

/// Something with named sheets the grid can switch between: an xlsx workbook or a SQLite
/// database (tables and views). `TableDocumentView` shows the names in the bar under the grid.
protocol SheetSource: AnyObject {
    var sheetNames: [String] { get }
    /// What to say in the status and the sheet's tooltip besides the name ("hidden in Excel", "view · 12 rows").
    func sheetNote(_ i: Int) -> String?
    func table(forSheet i: Int) throws -> TableData
}

/// A SQLite database opened read-only through the system library: every table and view is
/// a sheet, read with `SELECT *` up to `CSV.maxRows` rows. Values are spelled the way the
/// grid expects (NULL empty, integers exact, reals as General, blobs as a size).
final class SQLiteDatabase: SheetSource {
    struct Error: Swift.Error, CustomStringConvertible { let description: String }

    struct Entity {
        let name: String
        let kind: String   // "table" or "view"
        let rowCount: Int?
    }

    static let extensions: Set<String> = ["sqlite", "sqlite3", "db"]
    private static let magic = Data("SQLite format 3\0".utf8)

    let entities: [Entity]
    private let db: OpaquePointer

    /// True when the file starts with the SQLite header (used to tell a `.db` apart from other things called .db).
    static func isDatabase(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: magic.count)) == magic
    }

    init(url: URL) throws {
        guard Self.isDatabase(url) else { throw Error(description: "not a SQLite database") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close(handle) }
            throw Error(description: msg)
        }
        db = handle
        var list: [Entity] = []
        for row in try Self.rows(db, "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type, name") {
            let kind = row[0], name = row[1]
            var count: Int?
            if kind == "table", let c = try? Self.rows(db, "SELECT count(*) FROM \(Self.quote(name))").first?.first { count = Int(c) }
            list.append(Entity(name: name, kind: kind, rowCount: count))
        }
        entities = list
    }

    deinit { sqlite3_close(db) }

    var sheetNames: [String] { entities.map(\.name) }

    func sheetNote(_ i: Int) -> String? {
        guard entities.indices.contains(i) else { return nil }
        let e = entities[i]
        let f = NumberFormatter()
        f.numberStyle = .decimal
        if let n = e.rowCount { return "\(e.kind) · \(f.string(from: n as NSNumber)!) row\(n == 1 ? "" : "s")" }
        return e.kind
    }

    func table(forSheet i: Int) throws -> TableData {
        guard entities.indices.contains(i) else { return TableData(header: [], rows: [], totalRows: 0) }
        let e = entities[i]
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM \(Self.quote(e.name)) LIMIT \(CSV.maxRows)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Error(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let columns = Int(sqlite3_column_count(stmt))
        let header = (0..<columns).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[String]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append((0..<columns).map { Self.spell(stmt, Int32($0)) })
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Error(description: String(cString: sqlite3_errmsg(db)))
            }
        }
        let total = max(e.rowCount ?? rows.count, rows.count)
        var t = TableData(header: header, rows: rows, totalRows: total + 1)
        t.inferTypes()
        return t
    }

    private static func spell(_ stmt: OpaquePointer, _ c: Int32) -> String {
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_NULL: return ""
        case SQLITE_INTEGER: return String(sqlite3_column_int64(stmt, c))
        case SQLITE_FLOAT: return Formula.spellGeneral(sqlite3_column_double(stmt, c))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, c))
            return "<blob \(n) byte\(n == 1 ? "" : "s")>"
        default: return sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
        }
    }

    /// All rows of a query as text (for the catalogue queries).
    private static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Error(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(stmt)).map { spell(stmt, $0) })
        }
        return out
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
