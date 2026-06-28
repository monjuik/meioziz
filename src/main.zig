const std = @import("std");
const builtin = @import("builtin");

const Server = @import("server.zig").Server;
const config = @import("config.zig");
const Database = @import("db.zig").Database;

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

    const app_config = try config.load(io, allocator);

    var db = try Database.open(io, app_config.database);
    defer db.close();

    try db.migrate();

    const server = try Server.init(io, app_config);
    try server.run();
}
