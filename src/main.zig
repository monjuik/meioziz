const std = @import("std");
const Server = @import("server.zig").Server;
const config = @import("config.zig");
const builtin = @import("builtin");

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

    const server = try Server.init(io, app_config);
    try server.run();
}
