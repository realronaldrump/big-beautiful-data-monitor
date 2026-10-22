import Foundation
import GRDB
import MonitorEngine

/// The SQLite store: one write transaction per minute, minute detail for 30 days, hourly rows
/// forever. Failures degrade quietly: a corrupt file is set aside and a fresh one started.
public final class UsageDatabase: @unchecked Sendable {
    /// Minute rows older than this are deleted by the daily maintenance; hourly rows stay.
    public static let minuteRetention: TimeInterval = 30 * 24 * 3600
    static let maintenanceInterval: TimeInterval = 24 * 3600

    /// Nil for an in-memory database (tests).
    public let url: URL?
    /// Local hours and days. Injected so tests can pin a time zone.
    public let calendar: Calendar

    private let lock = NSLock()
    private var writer: any DatabaseWriter
    private var appIDs: [String: Int64] = [:]
    private var lastMaintenance: Date?

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Big Beautiful Data Monitor", directoryHint: .isDirectory)
            .appending(path: "Usage.sqlite")
    }

    /// Opens (or creates) the database at `url`. A corrupt file is moved aside, never deleted.
    public init(url: URL = UsageDatabase.defaultURL, calendar: Calendar = .autoupdatingCurrent) throws {
        self.url = url
        self.calendar = calendar
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            writer = try Self.open(url)
        } catch let error as DatabaseError where Self.isCorruption(error) {
            Self.setAside(url)
            writer = try Self.open(url)
        }
    }

    /// An in-memory database, for tests and experiments. (No default calendar on purpose: a bare
    /// `UsageDatabase()` must always mean the file on disk, never this.)
    public init(inMemoryWith calendar: Calendar) throws {
        url = nil
        self.calendar = calendar
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue)
        writer = queue
    }

    private static func open(_ url: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "Usage"
        configuration.qos = .utility
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try Schema.migrator.migrate(pool)
        let check = try pool.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
        guard check == "ok" else {
            try? pool.close()
            throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: check)
        }
        return pool
    }

    static func isCorruption(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Renames the file and its WAL companions to `Usage.sqlite.corrupt-<timestamp>`.
    static func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(filePath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let aside = URL(filePath: url.path + ".corrupt-\(stamp)" + suffix)
            try? FileManager.default.moveItem(at: file, to: aside)
        }
    }

    /// Runs `body`, and if the file turns out to be corrupt, sets it aside and retries on a fresh one.
    private func withRecovery<T>(_ body: (any DatabaseWriter) throws -> T) throws -> T {
        let current = lock.withLock { writer }
        do {
            return try body(current)
        } catch let error as DatabaseError where Self.isCorruption(error) {
            guard let url else { throw error }
            try? (current as? DatabasePool)?.close()
            Self.setAside(url)
            let fresh = try Self.open(url)
            lock.withLock {
                writer = fresh
                appIDs = [:]
            }
            return try body(fresh)
        } catch {
            // The transaction rolled back, so cached app IDs may point at rows that were never written.
            lock.withLock { appIDs = [:] }
            throw error
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try withRecovery { try $0.read(body) }
    }

    // MARK: - Writing

    /// Saves reconciled minutes in one transaction, adding to any rows already there
    /// (a minute flushed at sleep can receive more bytes after wake).
    public func save(_ minutes: [MinuteSummary]) throws {
        guard !minutes.isEmpty else { return }
        try withRecovery { writer in
            try writer.write { db in
                for summary in minutes { try insert(summary, db) }
            }
        }
        try fillMissingIconColors()
        try maintainIfDue(now: Date())
    }

    private func insert(_ summary: MinuteSummary, _ db: Database) throws {
        let minute = Int64(summary.minute.timeIntervalSince1970)
        let hour = Int64(calendar.dateInterval(of: .hour, for: summary.minute)!.start.timeIntervalSince1970)
        let network = summary.network.storageCode
        let idle = summary.idle

        try db.execute(sql: """
            INSERT INTO total_minute (minute, network, bytes_down, bytes_up, idle) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (minute, network) DO UPDATE SET
                bytes_down = bytes_down + excluded.bytes_down,
                bytes_up = bytes_up + excluded.bytes_up,
                idle = min(idle, excluded.idle)
            """, arguments: [minute, network, Int64(summary.total.down), Int64(summary.total.up), idle])
        try db.execute(sql: """
            INSERT INTO total_hour (hour, network, bytes_down, bytes_up, idle_down, idle_up, idle_minutes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (hour, network) DO UPDATE SET
                bytes_down = bytes_down + excluded.bytes_down,
                bytes_up = bytes_up + excluded.bytes_up,
                idle_down = idle_down + excluded.idle_down,
                idle_up = idle_up + excluded.idle_up,
                idle_minutes = idle_minutes + excluded.idle_minutes
            """, arguments: [hour, network, Int64(summary.total.down), Int64(summary.total.up),
                             idle ? Int64(summary.total.down) : 0, idle ? Int64(summary.total.up) : 0, idle ? 1 : 0])

        for (app, bytes) in summary.apps where !bytes.isZero {
            let appID = try id(for: app, db)
            try db.execute(sql: """
                INSERT INTO usage_minute (minute, app_id, network, bytes_down, bytes_up) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (minute, app_id, network) DO UPDATE SET
                    bytes_down = bytes_down + excluded.bytes_down,
                    bytes_up = bytes_up + excluded.bytes_up
                """, arguments: [minute, appID, network, Int64(bytes.down), Int64(bytes.up)])
            try db.execute(sql: """
                INSERT INTO usage_hour (hour, app_id, network, bytes_down, bytes_up, idle_down, idle_up)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (hour, app_id, network) DO UPDATE SET
                    bytes_down = bytes_down + excluded.bytes_down,
                    bytes_up = bytes_up + excluded.bytes_up,
                    idle_down = idle_down + excluded.idle_down,
                    idle_up = idle_up + excluded.idle_up
                """, arguments: [hour, appID, network, Int64(bytes.down), Int64(bytes.up),
                                 idle ? Int64(bytes.down) : 0, idle ? Int64(bytes.up) : 0])
        }
    }

    /// The row ID for an app, refreshing its name and path the first time it is seen this session.
    private func id(for app: AppIdentity, _ db: Database) throws -> Int64 {
        if let cached = lock.withLock({ appIDs[app.key] }) { return cached }
        let id = try Int64.fetchOne(db, sql: """
            INSERT INTO apps (key, display_name, kind, bundle_id, bundle_path, symbol_name) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET
                display_name = excluded.display_name,
                kind = excluded.kind,
                bundle_id = excluded.bundle_id,
                bundle_path = excluded.bundle_path,
                symbol_name = excluded.symbol_name
            RETURNING id
            """, arguments: [app.key, app.displayName, app.kind.rawValue, app.bundleID, app.bundlePath, app.symbolName])!
        lock.withLock { appIDs[app.key] = id }
        return id
    }

    /// Each app's color comes from its own icon, computed once and cached in the `apps` table.
    private func fillMissingIconColors() throws {
        let missing = try read { db in
            try Row.fetchAll(db, sql: "SELECT id, kind, bundle_path FROM apps WHERE icon_color IS NULL")
        }
        guard !missing.isEmpty else { return }
        let colors: [(id: Int64, color: UInt32)] = missing.map { row in
            let path: String? = row["bundle_path"]
            let isApp = (row["kind"] as String) == AppIdentity.Kind.app.rawValue
            return (row["id"], isApp && path != nil ? IconColor.dominant(forAppAt: path!) : IconColor.systemGray)
        }
        try withRecovery { writer in
            try writer.write { db in
                for entry in colors {
                    try db.execute(sql: "UPDATE apps SET icon_color = ? WHERE id = ?", arguments: [Int64(entry.color), entry.id])
                }
            }
        }
    }

    // MARK: - Maintenance

    /// Runs the daily maintenance if it has not run in the last 24 hours.
    public func maintainIfDue(now: Date) throws {
        if lastMaintenance == nil {
            lastMaintenance = try read { db in
                try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'last_maintenance'")
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast
            }
        }
        guard now.timeIntervalSince(lastMaintenance!) >= Self.maintenanceInterval else { return }
        try runMaintenance(now: now)
    }

    /// Deletes minute detail older than 30 days. The hourly rows already hold those minutes,
    /// because every minute is added to its hour when it is saved.
    public func runMaintenance(now: Date = Date()) throws {
        let cutoff = Int64(now.addingTimeInterval(-Self.minuteRetention).timeIntervalSince1970)
        try withRecovery { writer in
            try writer.write { db in
                try db.execute(sql: "DELETE FROM usage_minute WHERE minute < ?", arguments: [cutoff])
                try db.execute(sql: "DELETE FROM total_minute WHERE minute < ?", arguments: [cutoff])
                try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_maintenance', ?)",
                               arguments: [Int64(now.timeIntervalSince1970)])
            }
            try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA optimize") }
        }
        lastMaintenance = now
    }

    /// The "Reset data" setting: removes everything and starts empty.
    public func reset() throws {
        try withRecovery { writer in
            try writer.write { db in
                for table in ["usage_minute", "total_minute", "usage_hour", "total_hour", "apps", "meta"] {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
            try writer.vacuum()
        }
        lock.withLock { appIDs = [:] }
        lastMaintenance = nil
    }

    /// Bytes actually holding data (excluding free pages SQLite will reuse).
    public var dataSize: Int64 {
        (try? read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count")! - (try Int64.fetchOne(db, sql: "PRAGMA freelist_count")!)
            return try pages * Int64.fetchOne(db, sql: "PRAGMA page_size")!
        }) ?? 0
    }

    /// Size of the database file in bytes, including its write-ahead log.
    public var fileSize: Int64 {
        guard let url else { return 0 }
        return ["", "-wal"].reduce(0) { sum, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
