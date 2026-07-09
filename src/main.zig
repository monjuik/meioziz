const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");
const db = @import("db.zig");
const Database = db.Database;
const Server = @import("server.zig").Server;

const create_daily_hour_utc: i64 = 0;
const create_daily_minute_utc: i64 = 17;
const create_daily_time_ms: i64 = (create_daily_hour_utc * 60 + create_daily_minute_utc) * 60 * 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };

    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    const app_config = config.load(io, allocator) catch |err| switch (err) {
        error.MissingConfig => {
            std.log.err("config.zon is required", .{});
            return err;
        },
        error.MissingAdminHash => {
            std.log.err("config.zon must contain .admin_hash; generate it with: htpasswd -bnBC 12 \"\" 'your-password' | cut -d: -f2", .{});
            return err;
        },
        else => return err,
    };
    defer app_config.deinit(allocator);

    var database = try Database.open(io, app_config.database);
    defer database.close();

    try database.migrate();

    const create_daily_thread = try std.Thread.spawn(.{}, createDailyScheduler, .{ io, &database });
    create_daily_thread.detach();

    const server = try Server.init(io, &app_config, &database);
    try server.run();
}

fn nextCreateDailyMillis(now_ms: i64) i64 {
    const today_start = db.startOfDayMillis(now_ms);
    const today_run = today_start + create_daily_time_ms;
    if (now_ms < today_run) {
        return today_run;
    }
    return today_run + db.day_ms;
}

fn createDailyScheduler(io: std.Io, database: *Database) void {
    while (true) {
        const now = database.nowMillis();
        const next_run = nextCreateDailyMillis(now);
        const sleep_ms = next_run - now;

        std.log.info("Next daily aggregation scheduled in {d} ms", .{sleep_ms});

        const sleep_duration = std.Io.Duration.fromMilliseconds(sleep_ms);
        std.Io.sleep(io, sleep_duration, .real) catch |err| switch (err) {
            error.Canceled => return,
        };
        _ = database.createDailyAggregates(std.heap.smp_allocator) catch |err| {
            std.log.err("scheduled daily aggregation failed: {any}", .{err});
        };
    }
}

test "next aggregation time before scheduled time" {
    const day_start: i64 = 1782691200000;
    const before_run = day_start + 10 * 60 * 1000;

    try std.testing.expectEqual(
        day_start + 17 * 60 * 1000,
        nextCreateDailyMillis(before_run),
    );
}

test "next aggregation time after scheduled time" {
    const day_start: i64 = 1782691200000;
    const after_run = day_start + 20 * 60 * 1000;

    try std.testing.expectEqual(
        day_start + db.day_ms + 17 * 60 * 1000,
        nextCreateDailyMillis(after_run),
    );
}
