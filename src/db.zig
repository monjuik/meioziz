const std = @import("std");
const zqlite = @import("zqlite");
const event = @import("event.zig");

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

pub const Database = struct {
    conn: zqlite.Conn,
    io: std.Io,

    pub fn open(io: std.Io, path: [*:0]const u8) !Database {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        var db = Database{ .conn = conn, .io = io };
        try db.conn.busyTimeout(2000);
        try db.exec("PRAGMA journal_mode = WAL;");

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
    .{
        .name = "002_create_raw_app_idx",
        .sql =
        \\CREATE INDEX raw_app_idx ON raw (app);
        ,
    },
};

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
