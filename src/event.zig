const std = @import("std");

// we use this struct for parsing incoming HTTP-request
pub const EventRequest = struct {
    app: []const u8,
    code: []const u8,
    value: ?i64 = null,
    installId: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !EventRequest {
    const result = try std.json.parseFromSliceLeaky(
        EventRequest,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    );
    return result;
}

test "parse event request with value and installId" {
    const parsed = try parse(std.testing.allocator,
        \\{
        \\  "app": "pairception",
        \\  "code": "game-finished",
        \\  "value": 100,
        \\  "installId": "test-install"
        \\}
    );

    try std.testing.expectEqualStrings("pairception", parsed.app);
    try std.testing.expectEqualStrings("game-finished", parsed.code);
    try std.testing.expectEqual(@as(?i64, 100), parsed.value);
    try std.testing.expectEqualStrings("test-install", parsed.installId.?);
}

test "parse event request" {
    const parsed = try parse(std.testing.allocator,
        \\{
        \\  "app": "hex-fibonacci",
        \\  "code": "entered-shop"
        \\}
    );

    try std.testing.expectEqualStrings("hex-fibonacci", parsed.app);
    try std.testing.expectEqualStrings("entered-shop", parsed.code);
}
