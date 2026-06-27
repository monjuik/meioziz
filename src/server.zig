const std = @import("std");
const Socket = std.Io.net.Socket;
const Protocol = std.Io.net.Protocol;
const Config = @import("config.zig").Config;
const Request = @import("request.zig");

const Route = enum {
    index,
    event,
    login,
    app,
};

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

        var request_buffer: [1000]u8 = undefined;
        @memset(request_buffer[0..], 0);

        const request = try Request.read(self.io, connection, request_buffer[0..]);
        const route = matchRoute(request);

        if (route) |_| {
            try writeResponse(self.io, connection, "200 OK", "ok\n");
        } else {
            try writeResponse(self.io, connection, "404 Not Found", "not found\n");
        }
    }

    pub fn listen(self: Server) !std.Io.net.Server {
        std.log.info("Server started, receiving requests on: {s}:{any}", .{ self.host, self.port });
        return try self.addr.listen(self.io, .{ .mode = Socket.Mode.stream, .protocol = Protocol.tcp });
    }
};

fn matchRoute(request: Request.Request) ?Route {
    const path = request.path;

    switch (request.method) {
        .get => {
            if (std.mem.eql(u8, path, "/")) return .index;
            if (std.mem.startsWith(u8, path, "/app/") and path.len > "/app/".len) return .app;
        },
        .post => {
            if (std.mem.eql(u8, path, "/v1/event")) return .event;
            if (std.mem.eql(u8, path, "/login")) return .login;
        },
    }

    return null;
}

fn writeResponse(io: std.Io, connection: std.Io.net.Stream, status: []const u8, body: []const u8) !void {
    var send_buffer: [1024]u8 = undefined;
    var writer = connection.writer(io, &send_buffer);
    const writer_interface = &writer.interface;
    try writer_interface.print(
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\n{s}",
        .{ status, body.len, body },
    );

    try writer_interface.flush();
}
