const std = @import("std");

pub const Config = struct {
    port: u16 = 8123,
};

const FileConfig = struct {
    port: ?u16 = null,
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
    const file_config = try std.zon.parse.fromSlice(
        FileConfig,
        allocator,
        source,
        null,
        .{},
    );

    var result: Config = .{};

    if (file_config.port) |port| {
        result.port = port;
    }

    return result;
}

test "parse config port" {
    const parsed = try parse(
        \\.{
        \\    .port = 9000,
        \\}
    , std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 9000), parsed.port);
}

test "parse config default port" {
    const parsed = try parse(
        \\.{}
    , std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 8123), parsed.port);
}
