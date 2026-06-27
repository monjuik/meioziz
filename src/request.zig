const std = @import("std");
const Stream = std.Io.net.Stream;

pub const Method = enum {
    get,
    post,
};

pub const Request = struct {
    method: Method,
    path: []const u8,
};

pub fn read(io: std.Io, connection: Stream, buffer: []u8) !Request {
    var recv_buffer: [1024]u8 = undefined;
    var reader = connection.reader(io, &recv_buffer);
    const reader_interface = &reader.interface;

    const line = try reader_interface.takeDelimiterExclusive('\n');
    const trimmed_line = std.mem.trimEnd(u8, line, "\r");

    if (trimmed_line.len > buffer.len) {
        return error.RequestLineTooLong;
    }

    @memcpy(buffer[0..trimmed_line.len], trimmed_line);

    return try parseRequestLine(buffer[0..trimmed_line.len]);
}

fn parseMethod(raw_method: []const u8) !Method {
    if (std.mem.eql(u8, raw_method, "GET")) return .get;
    if (std.mem.eql(u8, raw_method, "POST")) return .post;

    return error.UnsupportedMethod;
}

fn parseRequestLine(line: []const u8) !Request {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const raw_method = parts.next() orelse return error.InvalidRequestLine;
    const path = parts.next() orelse return error.InvalidRequestLine;
    const version = parts.next() orelse return error.InvalidRequestLine;

    if (parts.next() != null) {
        return error.InvalidRequestLine;
    }

    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) {
        return error.UnsupportedHttpVersion;
    }
    return .{
        .method = try parseMethod(raw_method),
        .path = path,
    };
}

test "parse GET request line" {
    const request = try parseRequestLine("GET / HTTP/1.1");
    try std.testing.expectEqual(Method.get, request.method);
    try std.testing.expectEqualStrings("/", request.path);
}

test "parse POST request line" {
    const request = try parseRequestLine("POST /v1/event HTTP/1.1");
    try std.testing.expectEqual(Method.post, request.method);
    try std.testing.expectEqualStrings("/v1/event", request.path);
}

test "reject unsupported method" {
    try std.testing.expectError(
        error.UnsupportedMethod,
        parseRequestLine("PUT /v1/event HTTP/1.1"),
    );
}
