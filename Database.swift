// CodeLight — SQLite 持久化
import Foundation

// SQLITE_TRANSIENT 在 Swift 中不可直接用，手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ============================================================
// Database — SQLite 数据库封装（通过 SQLiteBridge.h 引入 sqlite3）
// ============================================================

class Database {
    static let shared = Database()
    private var db: OpaquePointer?
    private let dbPath: String

    struct Event {
        let id: Int64
        let timestamp: Double
        let state: String
        let message: String
        let sessionId: String
        let toolName: String
    }

    struct WorklogEntry {
        let id: Int64
        let timestamp: Double
        let toolName: String
        let sessionId: String
        let detail: String
    }

    private init() {
        let dir = NSHomeDirectory() + "/.codelight"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = dir + "/codelight.db"
    }

    func open() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[DB] 打开失败: \(dbPath)")
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

        let createSQL = """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                state TEXT NOT NULL,
                message TEXT NOT NULL,
                session_id TEXT NOT NULL DEFAULT '',
                tool_name TEXT DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS worklog (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                tool_name TEXT NOT NULL,
                session_id TEXT NOT NULL DEFAULT '',
                detail TEXT DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts ON events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_worklog_ts ON worklog(timestamp);
            CREATE TABLE IF NOT EXISTS secrets (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL DEFAULT ''
            );
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)
        // 收紧 db 文件权限：仅属主可读写（默认 -rw-r--r-- 过宽）
        chmod(dbPath, 0o600)
        cleanupEvents(days: 30)
        cleanupWorklog(days: 90)
    }

    // MARK: - Secrets（凭据存储：WebDAV 密码、S3 AK/SK 等）
    // 注意：SQLite 明文存储，文件权限 600。同账户其他进程仍可读，非绝对安全。

    /// 确保 db 已打开（懒打开，供 Config.load 早期调用）
    private func ensureOpen() {
        if db == nil { open() }
    }

    func setSecret(_ key: String, _ value: String) {
        ensureOpen()
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO secrets (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getSecret(_ key: String) -> String? {
        ensureOpen()
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        var result: String?
        let sql = "SELECT value FROM secrets WHERE key=?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    result = String(cString: cstr)
                }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func deleteSecret(_ key: String) {
        ensureOpen()
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM secrets WHERE key=?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Events

    func insertEvent(state: String, message: String, sessionId: String, toolName: String = "") {
        guard let db = db else { return }
        let ts = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "INSERT INTO events (timestamp, state, message, session_id, tool_name) VALUES (?, ?, ?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, state, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, message, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, toolName, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func queryEvents(since: Double = 0, limit: Int = 2000) -> [Event] {
        guard let db = db else { return [] }
        var results: [Event] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, timestamp, state, message, session_id, tool_name FROM events WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, since)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let toolPtr = sqlite3_column_text(stmt, 5)
                results.append(Event(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: sqlite3_column_double(stmt, 1),
                    state: String(cString: sqlite3_column_text(stmt, 2)),
                    message: String(cString: sqlite3_column_text(stmt, 3)),
                    sessionId: String(cString: sqlite3_column_text(stmt, 4)),
                    toolName: toolPtr != nil ? String(cString: toolPtr!) : ""
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results.reversed()
    }

    func cleanupEvents(days: Int) {
        guard let db = db else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(days * 86400)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM events WHERE timestamp < ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Worklog

    func insertWorklog(toolName: String, sessionId: String, detail: String = "") {
        guard let db = db else { return }
        let ts = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "INSERT INTO worklog (timestamp, tool_name, session_id, detail) VALUES (?, ?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, toolName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, detail, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func queryWorklog(since: Double = 0, limit: Int = 500) -> [WorklogEntry] {
        guard let db = db else { return [] }
        var results: [WorklogEntry] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, timestamp, tool_name, session_id, detail FROM worklog WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, since)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let detailPtr = sqlite3_column_text(stmt, 4)
                results.append(WorklogEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: sqlite3_column_double(stmt, 1),
                    toolName: String(cString: sqlite3_column_text(stmt, 2)),
                    sessionId: String(cString: sqlite3_column_text(stmt, 3)),
                    detail: detailPtr != nil ? String(cString: detailPtr!) : ""
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results.reversed()
    }

    func cleanupWorklog(days: Int) {
        guard let db = db else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(days * 86400)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM worklog WHERE timestamp < ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Stats

    func todayActiveDuration() -> TimeInterval {
        guard let db = db else { return 0 }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date()).timeIntervalSince1970
        var stmt: OpaquePointer?
        var total: Double = 0
        var lastTs: Double = 0
        let sql = "SELECT timestamp FROM events WHERE timestamp >= ? AND state != 'idle' ORDER BY timestamp ASC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, todayStart)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_double(stmt, 0)
                if lastTs > 0 {
                    let gap = ts - lastTs
                    if gap < 300 { total += gap }
                }
                lastTs = ts
            }
        }
        sqlite3_finalize(stmt)
        return total
    }

    func toolCallCount(since: Double) -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        var count: Int = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events WHERE timestamp >= ? AND tool_name != ''", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, since)
            if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return count
    }
}
