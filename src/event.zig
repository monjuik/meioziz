const std = @import("std");
const config = @import("config.zig");

const max_length = 128;

// we use this struct for parsing incoming HTTP-request
pub const EventRequest = struct {
    app: []const u8,
    code: []const u8,
    value: ?i64 = null,
    installId: ?[]const u8 = null,
};

pub const Event = struct {
    app: *const config.App,
    code: []const u8,
    value: ?i64,
    installId: ?[]const u8,

    pub fn init(app_config: *const config.Config, request: EventRequest) !Event {
        const key = std.mem.trim(u8, request.app, " \t\r\n");
        if (key.len == 0) return error.EmptyApp;
        if (key.len > max_length) return error.AppTooLong;
        if (!isValidCode(key)) return error.InvalidApp;

        const code = std.mem.trim(u8, request.code, " \t\r\n");
        if (code.len == 0) return error.EmptyCode;
        if (code.len > max_length) return error.CodeTooLong;
        if (!isValidCode(code)) return error.InvalidCode;

        if (request.installId) |install_id| {
            if (install_id.len > max_length) return error.InstallIdTooLong;
        }

        const app = app_config.findApp(key) orelse return error.UnknownApp;
        if (!app.active) return error.InactiveApp;

        return .{
            .app = app,
            .code = code,
            .value = request.value,
            .installId = request.installId,
        };
    }
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

fn isValidCode(value: []const u8) bool {
    for (value) |char| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', ' ' => {},
            else => return false,
        }
    }
    return true;
}

fn testConfig(active: bool) config.Config {
    const apps = struct {
        var items = [_]config.App{
            .{ .name = "Pairception", .key = "pairception", .active = true },
        };
    };

    apps.items[0].active = active;
    return config.Config{ .apps = &apps.items };
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

test "create event from request" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = " pairception ",
        .code = " game-finished ",
        .value = 100,
        .installId = "test-install",
    };

    const created = try Event.init(&app_config, request);

    try std.testing.expectEqualStrings("pairception", created.app.key);
    try std.testing.expectEqualStrings("game-finished", created.code);
    try std.testing.expectEqual(@as(?i64, 100), created.value);
    try std.testing.expectEqualStrings("test-install", created.installId.?);
}

test "reject event with empty app" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "   ",
        .code = "game-finished",
    };

    try std.testing.expectError(error.EmptyApp, Event.init(&app_config, request));
}

test "reject event with empty code" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "pairception",
        .code = "   ",
    };

    try std.testing.expectError(error.EmptyCode, Event.init(&app_config, request));
}

test "reject event with unknown app" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "unknown",
        .code = "game-finished",
    };

    try std.testing.expectError(error.UnknownApp, Event.init(&app_config, request));
}

test "reject event with inactive app" {
    const app_config = testConfig(false);

    const request = EventRequest{
        .app = "pairception",
        .code = "game-finished",
    };

    try std.testing.expectError(error.InactiveApp, Event.init(&app_config, request));
}

test "allow valid event code characters" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "pairception",
        .code = "Game-123.finished_ok",
    };

    const created = try Event.init(&app_config, request);

    try std.testing.expectEqualStrings("Game-123.finished_ok", created.code);
}

test "reject invalid app characters" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "pairception🔥",
        .code = "game-finished",
    };

    try std.testing.expectError(error.InvalidApp, Event.init(&app_config, request));
}

test "reject invalid code characters" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "pairception",
        .code = "game finished 🙈",
    };

    try std.testing.expectError(error.InvalidCode, Event.init(&app_config, request));
}

test "reject too long install id" {
    const app_config = testConfig(true);

    const request = EventRequest{
        .app = "pairception",
        .code = "game-finished",
        .installId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };

    try std.testing.expectError(error.InstallIdTooLong, Event.init(&app_config, request));
}
