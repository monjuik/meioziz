const std = @import("std");

const zqlite = @import("zqlite");

const event = @import("event.zig");

pub const day_ms: i64 = 86_400_000;
pub const show_daily_depth: i64 = 28;

const create_migration_table_sql =
    \\CREATE TABLE IF NOT EXISTS migration(
    \\   name     TEXT PRIMARY KEY,
    \\   executed INTEGER NOT NULL
    \\);
;

const Migration = struct {
    name: []const u8,
    sql: [:0]const u8,
};

pub const AppEventCount = struct {
    app_key: []const u8,
    count: i64,
};

pub const AggregateResult = struct {
    days: i64 = 0,
    events_deleted: i64 = 0,
    elapsed_ms: i64 = 0,
};

pub const DailyAggregate = struct {
    day: i64,
    code: []const u8,
    count: i64,
    uniques: ?i64,
    min: ?i64,
    max: ?i64,
    avg: ?i64,
};

pub const Database = struct {
    conn: zqlite.Conn,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn open(io: std.Io, path: [*:0]const u8) !Database {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        var db = Database{ .conn = conn, .io = io };
        try db.conn.busyTimeout(2000);
        try db.exec("PRAGMA journal_mode = WAL;");
        try db.exec("PRAGMA synchronous = NORMAL;");

        return db;
    }

    pub fn close(self: *Database) void {
        self.conn.close();
    }

    pub fn exec(self: *Database, sql: [:0]const u8) !void {
        try self.conn.execNoArgs(sql);
    }

    fn ensureMigrationTable(self: *Database) !void {
        try self.exec(create_migration_table_sql);
    }

    pub fn migrate(self: *Database) !void {
        try self.ensureMigrationTable();

        for (migrations) |migration| {
            try self.applyMigration(migration);
        }
    }

    pub fn insertEvent(self: *Database, e: event.Event) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.conn.exec(
            \\INSERT INTO raw (
            \\    received,
            \\    app,
            \\    code,
            \\    value,
            \\    install_id,
            \\    data
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ,
            .{
                self.nowMillis(),
                e.app.key,
                e.code,
                e.value,
                e.installId,
                null,
            },
        );
    }

    pub fn countEventsByAppSince(
        self: *Database,
        allocator: std.mem.Allocator,
        since_ms: i64,
    ) ![]AppEventCount {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var result: std.ArrayList(AppEventCount) = .empty;
        errdefer result.deinit(allocator);

        var rows = try self.conn.rows(
            \\SELECT app, COUNT(*)
            \\FROM raw
            \\WHERE received >= ?1
            \\GROUP BY app
        ,
            .{since_ms},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            try result.append(allocator, .{
                .app_key = try allocator.dupe(u8, row.text(0)),
                .count = row.int(1),
            });
        }
        return try result.toOwnedSlice(allocator);
    }

    pub fn dailyAggregatesByApp(
        self: *Database,
        allocator: std.mem.Allocator,
        app_key: []const u8,
    ) ![]DailyAggregate {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var result: std.ArrayList(DailyAggregate) = .empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.code);
            }
            result.deinit(allocator);
        }

        const since = startOfDayMillis(self.nowMillis()) - show_daily_depth * day_ms;
        var rows = try self.conn.rows(
            \\SELECT day, code, count, uniques, min, max, avg
            \\FROM daily
            \\WHERE app = ?1 AND day >= ?2
            \\ORDER BY code ASC, day DESC
        ,
            .{ app_key, since },
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            try result.append(allocator, .{
                .day = row.int(0),
                .code = try allocator.dupe(u8, row.text(1)),
                .count = row.int(2),
                .uniques = row.nullableInt(3),
                .min = row.nullableInt(4),
                .max = row.nullableInt(5),
                .avg = row.nullableInt(6),
            });
        }

        return try result.toOwnedSlice(allocator);
    }

    fn isMigrationApplied(self: *Database, name: []const u8) !bool {
        const row = try self.conn.row(
            "SELECT name FROM migration WHERE name = ?1",
            .{name},
        ) orelse return false;
        defer row.deinit();

        return true;
    }

    fn markMigrationApplied(self: *Database, name: []const u8) !void {
        try self.conn.exec(
            "INSERT INTO migration (name, executed) VALUES (?1, ?2)",
            .{ name, self.nowMillis() },
        );
    }

    fn applyMigration(self: *Database, migration: Migration) !void {
        if (try self.isMigrationApplied(migration.name)) {
            return;
        }

        std.log.info("Applying database migration: {s}", .{migration.name});

        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.exec(migration.sql);
        try self.markMigrationApplied(migration.name);

        try self.conn.commit();

        std.log.info("Applied database migration: {s}", .{migration.name});
    }

    pub fn createDailyAggregates(self: *Database, allocator: std.mem.Allocator) !AggregateResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const started = self.nowMillis();
        const today = startOfDayMillis(started);
        const days = try self.daysToProcess(allocator, today);
        defer allocator.free(days);

        var result: AggregateResult = .{ .days = @intCast(days.len) };

        try self.conn.transaction();
        errdefer self.conn.rollback();

        for (days) |day| {
            const next_day = day + day_ms;
            const events_count = try self.countEventsBetween(day, next_day);
            // as we use system date and time for the event,
            // it's highly unlikely to have raw events and stored daily aggregates,
            // that's why we ignore them and delete
            try self.conn.exec(
                \\INSERT OR IGNORE INTO daily (
                \\    day,
                \\    app,
                \\    code,
                \\    count,
                \\    uniques,
                \\    min,
                \\    max,
                \\    avg
                \\)
                \\SELECT
                \\    ?1,
                \\    app,
                \\    code,
                \\    COUNT(*),
                \\    CASE WHEN COUNT(install_id) = 0 THEN NULL ELSE COUNT(DISTINCT install_id) END,
                \\    MIN(value),
                \\    MAX(value),
                \\    CAST(ROUND(AVG(value), 0) AS INTEGER)
                \\FROM raw
                \\WHERE received >= ?1 AND received < ?2
                \\GROUP BY app, code
            ,
                .{ day, next_day },
            );

            try self.conn.exec(
                "DELETE FROM raw WHERE received >= ?1 AND received < ?2",
                .{ day, next_day },
            );
            result.events_deleted += events_count;
        }
        try self.conn.commit();
        result.elapsed_ms = self.nowMillis() - started;
        std.log.info(
            "Daily aggregation finished: days={d}, events_deleted={d}, elapsed_ms={d}",
            .{ result.days, result.events_deleted, result.elapsed_ms },
        );
        return result;
    }

    fn daysToProcess(self: *Database, allocator: std.mem.Allocator, before_ms: i64) ![]i64 {
        var result: std.ArrayList(i64) = .empty;
        errdefer result.deinit(allocator);
        var rows = try self.conn.rows(
            \\SELECT DISTINCT (received / ?1) * ?1
            \\FROM raw
            \\WHERE received < ?2
            \\ORDER BY 1
        ,
            .{ day_ms, before_ms },
        );
        defer rows.deinit();
        while (rows.next()) |row| {
            try result.append(allocator, row.int(0));
        }
        return try result.toOwnedSlice(allocator);
    }

    fn countEventsBetween(self: *Database, from_ms: i64, to_ms: i64) !i64 {
        const row = try self.conn.row(
            "SELECT COUNT(*) FROM raw WHERE received >= ?1 AND received < ?2",
            .{ from_ms, to_ms },
        ) orelse return 0;
        defer row.deinit();

        return row.int(0);
    }

    pub fn nowMillis(self: *Database) i64 {
        const now = std.Io.Clock.now(.real, self.io);
        return @intCast(@divTrunc(now.nanoseconds, 1_000_000));
    }
};

const migrations = [_]Migration{
    .{
        .name = "001_create_raw",
        .sql =
        \\CREATE TABLE raw (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    received INTEGER NOT NULL,
        \\    app TEXT NOT NULL,
        \\    code TEXT NOT NULL,
        \\    value INTEGER,
        \\    install_id TEXT,
        \\    data TEXT
        \\);
        ,
    },
    .{ .name = "002_create_raw_received_app_code_idx", .sql =
    \\CREATE INDEX raw_received_app_code_idx ON raw (received, app, code);
    },
    .{
        .name = "003_create_daily",
        .sql =
        \\CREATE TABLE daily (
        \\    day INTEGER NOT NULL,
        \\    app TEXT NOT NULL,
        \\    code TEXT NOT NULL,
        \\    count INTEGER NOT NULL,
        \\    uniques INTEGER,
        \\    min INTEGER,
        \\    max INTEGER,
        \\    avg INTEGER,
        \\    PRIMARY KEY (day, app, code)
        \\);
        , // 'unique' is a reserved keyword, thus we are using uniques
    },
    .{ .name = "004_create_daily_app_code_day_idx", .sql =
    \\CREATE INDEX daily_app_code_day_idx ON daily (app, code, day DESC);
    },
};

pub fn startOfDayMillis(now_ms: i64) i64 {
    return @divFloor(now_ms, day_ms) * day_ms;
}

test "migrate creates raw table and records migration" {
    const io = std.testing.io;
    var db = try Database.open(io, ":memory:");
    defer db.close();

    try db.migrate();
    try db.migrate(); // let's check idempotency

    const migration_count = try db.conn.row(
        "SELECT COUNT(*) FROM migration WHERE name = ?1",
        .{"001_create_raw"},
    ) orelse return error.MigrationNotFound;
    defer migration_count.deinit();

    try std.testing.expectEqual(@as(i64, 1), migration_count.int(0));

    try std.testing.expectEqual(true, try db.isMigrationApplied("001_create_raw"));

    const row = try db.conn.row(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
        .{"raw"},
    ) orelse return error.RawTableNotFound;
    defer row.deinit();

    try std.testing.expectEqualStrings("raw", row.text(0));
}

test "aggregate complete raw days" {
    const io = std.testing.io;
    var db = try Database.open(io, ":memory:");
    defer db.close();

    try db.migrate();

    const day: i64 = 1782691200000;
    const today: i64 = startOfDayMillis(db.nowMillis());

    try db.conn.exec(
        \\INSERT INTO raw (received, app, code, value, install_id, data) VALUES
        \\(?1, 'pairception', 'game-finished', 10, 'a', NULL),
        \\(?1, 'pairception', 'game-finished', 20, 'a', NULL),
        \\(?1, 'pairception', 'game-finished', 32, 'b', NULL),
        \\(?1, 'pairception', 'shop-opened', NULL, NULL, NULL),
        \\(?2, 'pairception', 'today-event', 100, 'c', NULL)
    ,
        .{ day, today },
    );

    const result = try db.createDailyAggregates(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 1), result.days);
    try std.testing.expectEqual(@as(i64, 4), result.events_deleted);

    const aggregate = try db.conn.row(
        \\SELECT count, uniques, min, max, avg
        \\FROM daily
        \\WHERE day = ?1 AND app = 'pairception' AND code = 'game-finished'
    ,
        .{day},
    ) orelse return error.AggregateNotFound;
    defer aggregate.deinit();

    try std.testing.expectEqual(@as(i64, 3), aggregate.int(0));
    try std.testing.expectEqual(@as(i64, 2), aggregate.int(1));
    try std.testing.expectEqual(@as(i64, 10), aggregate.int(2));
    try std.testing.expectEqual(@as(i64, 32), aggregate.int(3));
    try std.testing.expectEqual(@as(i64, 21), aggregate.int(4));

    const remaining_raw = try db.conn.row("SELECT COUNT(*) FROM raw", .{}) orelse return error.RawCountNotFound;
    defer remaining_raw.deinit();

    try std.testing.expectEqual(@as(i64, 1), remaining_raw.int(0));
}
