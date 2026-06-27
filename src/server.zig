const std = @import("std");
const Socket = std.Io.net.Socket;
const Protocol = std.Io.net.Protocol;
const Config = @import("config.zig").Config;
const event = @import("event.zig");

const Route = enum {
    index,
    event,
    login,
    app,
};

const text_plain_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain" },
};

const max_event_body_size = 16 * 1024;

pub const Server = struct {
    host: []const u8,
    port: u16,
    addr: std.Io.net.IpAddress,
    io: std.Io,

    pub fn init(io: std.Io, config: Config) !Server {
        const host: []const u8 = "0.0.0.0";
        const port: u16 = config.port;
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);

        return .{ .host = host, .port = port, .addr = addr, .io = io };
    }

    pub fn run(self: Server) !void {
        var listening = try self.listen();
        while (true) {
            const connection = try listening.accept(self.io);
            self.handleConnection(connection) catch |err| {
                std.log.err("connection error: {any}", .{err});
            };
        }
    }

    fn handleConnection(self: Server, connection: std.Io.net.Stream) !void {
        defer connection.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;

        var stream_reader = std.Io.net.Stream.Reader.init(connection, self.io, &read_buffer);
        var stream_writer = std.Io.net.Stream.Writer.init(connection, self.io, &write_buffer);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        _ = &http_server;

        var request = try http_server.receiveHead();
        const route = matchRoute(request.head.method, request.head.target);

        const matched_route = route orelse {
            try respondNotFound(&request);
            return;
        };

        var request_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer request_arena.deinit();

        const allocator = request_arena.allocator();

        switch (matched_route) {
            .event => {
                const content_length = request.head.content_length orelse {
                    try respondBadRequest(&request);
                    return;
                };

                if (content_length > max_event_body_size) {
                    try respondBadRequest(&request);
                    return;
                }

                var body_buffer: [4096]u8 = undefined;
                var body_reader = request.readerExpectNone(&body_buffer);
                const body = body_reader.readAlloc(allocator, @intCast(content_length)) catch {
                    try respondBadRequest(&request);
                    return;
                };

                _ = event.parse(allocator, body) catch {
                    try respondBadRequest(&request);
                    return;
                };

                try request.respond("", .{
                    .status = .no_content,
                    .keep_alive = false,
                });
            },
            else => {
                try request.respond("ok\n", .{
                    .status = .ok,
                    .keep_alive = false,
                    .extra_headers = &text_plain_headers,
                });
            },
        }
    }

    pub fn listen(self: Server) !std.Io.net.Server {
        std.log.info("Server started, receiving requests on: {s}:{any}", .{ self.host, self.port });
        return try self.addr.listen(self.io, .{ .mode = Socket.Mode.stream, .protocol = Protocol.tcp });
    }
};

fn matchRoute(method: std.http.Method, path: []const u8) ?Route {
    switch (method) {
        .GET => {
            if (std.mem.eql(u8, path, "/")) return .index;
            if (std.mem.startsWith(u8, path, "/app/") and path.len > "/app/".len) return .app;
        },
        .POST => {
            if (std.mem.eql(u8, path, "/v1/event")) return .event;
            if (std.mem.eql(u8, path, "/login")) return .login;
        },
        else => {},
    }

    return null;
}

fn respondBadRequest(request: *std.http.Server.Request) !void {
    try request.respond("bad request\n", .{
        .status = .bad_request,
        .keep_alive = false,
        .extra_headers = &text_plain_headers,
    });
}
fn respondNotFound(request: *std.http.Server.Request) !void {
    try request.respond("not found\n", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &text_plain_headers,
    });
}

test "match allowed routes" {
    try std.testing.expectEqual(Route.index, matchRoute(.GET, "/"));
    try std.testing.expectEqual(Route.app, matchRoute(.GET, "/app/pairception"));
    try std.testing.expectEqual(Route.event, matchRoute(.POST, "/v1/event"));
    try std.testing.expectEqual(Route.login, matchRoute(.POST, "/login"));
}

test "reject unknown routes" {
    try std.testing.expectEqual(null, matchRoute(.GET, "/unknown"));
    try std.testing.expectEqual(null, matchRoute(.POST, "/"));
    try std.testing.expectEqual(null, matchRoute(.GET, "/v1/event"));
    try std.testing.expectEqual(null, matchRoute(.PUT, "/v1/event"));
}
