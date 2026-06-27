const std = @import("std");
const Server = @import("server.zig").Server;
const config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // we use this allocator in debug
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    // we use this one for production
    // const allocator = std.heap.smp_allocator;

    const allocator = debug_allocator.allocator();
    const app_config = try config.load(io, allocator);

    const server = try Server.init(io, app_config);
    try server.run();
}
