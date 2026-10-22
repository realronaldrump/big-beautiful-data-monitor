import GRDB
import MonitorEngine

/// The database layout. Times are Unix seconds: `minute` is the start of a minute, `hour` the
/// start of a local hour (so days split cleanly at local midnight in every time zone).
enum Schema {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE apps (
                    id INTEGER PRIMARY KEY,
                    key TEXT NOT NULL UNIQUE,          -- bundle ID, or system.<slug> for system groups
                    display_name TEXT NOT NULL,
                    kind TEXT NOT NULL,                -- 'app' or 'system'
                    bundle_id TEXT,
                    bundle_path TEXT,                  -- for the icon
                    symbol_name TEXT,                  -- SF Symbol for system groups
                    icon_color INTEGER                 -- 0xRRGGBB from the icon, computed once
                );

                CREATE TABLE usage_minute (
                    minute INTEGER NOT NULL,
                    app_id INTEGER NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
                    network INTEGER NOT NULL,
                    bytes_down INTEGER NOT NULL,
                    bytes_up INTEGER NOT NULL,
                    PRIMARY KEY (minute, app_id, network)
                ) WITHOUT ROWID;

                CREATE TABLE total_minute (
                    minute INTEGER NOT NULL,
                    network INTEGER NOT NULL,
                    bytes_down INTEGER NOT NULL,
                    bytes_up INTEGER NOT NULL,
                    idle INTEGER NOT NULL,             -- 1 when nobody touched the keyboard or mouse
                    PRIMARY KEY (minute, network)
                ) WITHOUT ROWID;

                -- Hourly rows are kept up to date every minute and kept forever.
                -- idle_* hold the bytes that moved during idle minutes, for "While you were away".
                CREATE TABLE usage_hour (
                    hour INTEGER NOT NULL,
                    app_id INTEGER NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
                    network INTEGER NOT NULL,
                    bytes_down INTEGER NOT NULL,
                    bytes_up INTEGER NOT NULL,
                    idle_down INTEGER NOT NULL,
                    idle_up INTEGER NOT NULL,
                    PRIMARY KEY (hour, app_id, network)
                ) WITHOUT ROWID;
                CREATE INDEX usage_hour_by_app ON usage_hour (app_id, hour);

                CREATE TABLE total_hour (
                    hour INTEGER NOT NULL,
                    network INTEGER NOT NULL,
                    bytes_down INTEGER NOT NULL,
                    bytes_up INTEGER NOT NULL,
                    idle_down INTEGER NOT NULL,
                    idle_up INTEGER NOT NULL,
                    idle_minutes INTEGER NOT NULL,
                    PRIMARY KEY (hour, network)
                ) WITHOUT ROWID;

                CREATE TABLE meta (
                    key TEXT PRIMARY KEY,
                    value INTEGER NOT NULL
                );
                """)
        }
        return migrator
    }()
}

extension NetworkKind {
    /// Compact codes for storage. Never renumber these.
    var storageCode: Int {
        switch self {
        case .offline: 0
        case .wifi: 1
        case .wired: 2
        case .hotspot: 3
        case .other: 4
        }
    }

    init(storageCode: Int) {
        self = switch storageCode {
        case 1: .wifi
        case 2: .wired
        case 3: .hotspot
        case 4: .other
        default: .offline
        }
    }
}
