const std = @import("std");

pub const Config = struct {
    port: u16 = 8123,
    database: [*:0]const u8 = "meioziz.db",
    apps: []App = &.{},

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        for (self.apps) |app| {
            allocator.free(app.name);
            allocator.free(app.key);
        }
        allocator.free(self.apps);
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
        error.FileNotFound => return .{},
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

    var result: Config = .{};

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
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 9000), parsed.port);
}

test "parse config default port" {
    const parsed = try parse(
        \\.{}
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
        \\}
    , std.testing.allocator);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, parsed.findApp("unknown"));
}
