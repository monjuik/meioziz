const std = @import("std");

pub const Config = struct {
    port: u16 = 8123,
    database: [*:0]const u8 = "meioziz.db",
    apps: []App = &.{},
    admin_hash: []const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        for (self.apps) |app| {
            allocator.free(app.name);
            allocator.free(app.key);
        }
        allocator.free(self.apps);
        allocator.free(self.admin_hash);
    }

    pub fn findApp(self: *const Config, key: []const u8) ?*const App {
        for (self.apps) |*app| {
            if (std.mem.eql(u8, app.key, key)) {
                return app;
            }
        }
        return null;
    }
};

pub const App = struct {
    name: []const u8,
    key: []const u8,
    active: bool = true,
};

const FileConfig = struct {
    port: ?u16 = null,
    admin_hash: ?[]const u8 = null,
    apps: ?[]const App = null,
    // didn't add FileApp on purpose, because it would have the same fields.
    // if some day there will be differencies, we'll introduce FileApp struct
};

pub fn load(io: std.Io, allocator: std.mem.Allocator) !Config {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "config.zon",
        allocator,
        .limited(16 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingConfig,
        else => return err,
    };
    defer allocator.free(source);
    return try parse(source, allocator);
}

fn parse(source: [:0]const u8, allocator: std.mem.Allocator) !Config {
    const file_config = try std.zon.parse.fromSliceAlloc(
        FileConfig,
        allocator,
        source,
        null,
        .{},
    );
    defer std.zon.parse.free(allocator, file_config);

    const admin_hash = file_config.admin_hash orelse return error.MissingAdminHash;
    var result: Config = .{
        .admin_hash = try allocator.dupe(u8, admin_hash),
    };
    errdefer allocator.free(result.admin_hash);

    if (file_config.port) |port| {
        result.port = port;
    }

    if (file_config.apps) |apps| {
        result.apps = try allocator.alloc(App, apps.len);
        errdefer allocator.free(result.apps);

        var copied: usize = 0;
        errdefer {
            for (result.apps[0..copied]) |app| {
                allocator.free(app.name);
                allocator.free(app.key);
            }
        }

        for (apps, 0..) |app, i| {
            result.apps[i] = .{
                .name = try allocator.dupe(u8, app.name),
                .key = try allocator.dupe(u8, app.key),
                .active = app.active,
            };
            copied += 1;
        }
    }

    return result;
}

test "parse config port" {
    const parsed = try parse(
        \\.{
        \\    .port = 9000,
        \\    .admin_hash = "",
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 9000), parsed.port);
}

test "parse config default port" {
    const parsed = try parse(
        \\.{ .admin_hash = "" }
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 8123), parsed.port);
}

test "parse config app default active" {
    const parsed = try parse(
        \\.{
        \\    .apps = .{
        \\        .{
        \\            .name = "Pairception",
        \\            .key = "pairception",
        \\        },
        \\    },
        \\    .admin_hash = "",
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, parsed.apps[0].active);
}

test "find app by key" {
    const parsed = try parse(
        \\.{
        \\    .apps = .{
        \\        .{
        \\            .name = "Pairception",
        \\            .key = "pairception",
        \\            .active = true,
        \\        },
        \\    },
        \\    .admin_hash = "",
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    const app = parsed.findApp("pairception") orelse return error.AppNotFound;

    try std.testing.expectEqualStrings("Pairception", app.name);
    try std.testing.expectEqualStrings("pairception", app.key);
    try std.testing.expectEqual(true, app.active);
}

test "find app returns null for unknown key" {
    const parsed = try parse(
        \\.{
        \\    .apps = .{
        \\        .{
        \\            .name = "Pairception",
        \\            .key = "pairception",
        \\        },
        \\    },
        \\   .admin_hash = "",
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, parsed.findApp("unknown"));
}

test "parse config admin hash" {
    const parsed = try parse(
        \\.{
        \\    .admin_hash = "$2y$12$qBlpx4Y61WRU7bIrhSGdwOyJumNNH/fChk40axsUWbF0NsSTy8uI2",
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "$2y$12$qBlpx4Y61WRU7bIrhSGdwOyJumNNH/fChk40axsUWbF0NsSTy8uI2",
        parsed.admin_hash,
    );
}
