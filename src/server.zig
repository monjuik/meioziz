const std = @import("std");
const Socket = std.Io.net.Socket;
const Protocol = std.Io.net.Protocol;

const config = @import("config.zig");
const Config = config.Config;
const db = @import("db.zig");
const Database = db.Database;
const event = @import("event.zig");

const Route = enum {
    index,
    event,
    login,
    app,
    createDaily,
};

const DashboardApp = struct {
    app: *const config.App,
    count: i64,
};

const text_plain_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain" },
};

const text_html_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
};

const max_event_body_size = 16 * 1024;

pub const Server = struct {
    host: []const u8,
    port: u16,
    addr: std.Io.net.IpAddress,
    io: std.Io,
    db: *Database,
    config: Config,

    pub fn init(io: std.Io, cfg: Config, database: *Database) !Server {
        const host: []const u8 = "0.0.0.0";
        const port: u16 = cfg.port;
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);

        return .{ .host = host, .port = port, .addr = addr, .io = io, .db = database, .config = cfg };
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

        var request = try http_server.receiveHead();
        try self.handleRequest(&request);
    }

    fn handleRequest(self: Server, request: *std.http.Server.Request) !void {
        const route = matchRoute(request.head.method, request.head.target) orelse {
            try respondNotFound(request);
            return;
        };

        switch (route) {
            .event => try self.handleEvent(request),
            .login => try handleLogin(request),
            .index => try self.handleIndex(request),
            .app => try self.handleApp(request),
            .createDaily => try self.handleCreateDaily(request),
        }
    }

    fn handleEvent(self: Server, request: *std.http.Server.Request) !void {
        var request_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer request_arena.deinit();

        const allocator = request_arena.allocator();

        const content_length = request.head.content_length orelse {
            try respondBadRequest(request);
            return;
        };

        if (content_length > max_event_body_size) {
            try respondBadRequest(request);
            return;
        }

        var body_buffer: [4096]u8 = undefined;
        var body_reader = request.readerExpectNone(&body_buffer);
        const body = body_reader.readAlloc(allocator, @intCast(content_length)) catch {
            try respondBadRequest(request);
            return;
        };

        const event_request = event.parse(allocator, body) catch {
            try respondBadRequest(request);
            return;
        };

        const created_event = event.Event.init(&self.config, event_request) catch |err| {
            std.log.err("invalid event: {any}", .{err});
            try respondBadRequest(request);
            return;
        };
        self.db.insertEvent(created_event) catch |err| {
            std.log.err("failed to insert event: {any}", .{err});
            try respondInternalError(request);
            return;
        };

        try respondNoContent(request);
    }

    fn handleIndex(self: Server, request: *std.http.Server.Request) !void {
        const since_ms = startOfDayMillis(self.db.nowMillis());

        var request_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer request_arena.deinit();

        const allocator = request_arena.allocator();
        const counts = self.db.countEventsByAppSince(allocator, since_ms) catch |err| {
            std.log.err("failed to load dashboard counts: {any}", .{err});
            try respondInternalError(request);
            return;
        };
        var apps: std.ArrayList(DashboardApp) = .empty;
        for (self.config.apps) |*app| {
            if (!app.active) continue;

            try apps.append(allocator, .{
                .app = app,
                .count = findEventCount(counts, app.key),
            });
        }
        std.mem.sort(
            DashboardApp,
            apps.items,
            {},
            lessThanDashboardApp,
        );
        const html = try renderPage(allocator, apps.items);
        try respondHtml(request, html, .ok);
    }

    fn handleCreateDaily(self: Server, request: *std.http.Server.Request) !void {
        var request_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer request_arena.deinit();

        const allocator = request_arena.allocator();

        // intentionally unauthenticated for now: aggregation is idempotent
        const result = self.db.createDailyAggregates(allocator) catch |err| {
            std.log.err("failed to run daily aggregation: {any}", .{err});
            try respondInternalError(request);
            return;
        };

        const body = try std.fmt.allocPrint(
            allocator,
            "ok days={d} events_deleted={d} elapsed_ms={d}\n",
            .{ result.days, result.events_deleted, result.elapsed_ms },
        );

        try respondText(request, body, .ok);
    }

    fn handleApp(self: Server, request: *std.http.Server.Request) !void {
        const app_key = appKeyFromPath(request.head.target) orelse {
            try respondNotFound(request);
            return;
        };

        const app = self.config.findApp(app_key) orelse {
            try respondNotFound(request);
            return;
        };

        var request_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer request_arena.deinit();

        const allocator = request_arena.allocator();

        const aggregates = self.db.dailyAggregatesByApp(allocator, app.key) catch |err| {
            std.log.err("failed to load daily aggregates: {any}", .{err});
            try respondInternalError(request);
            return;
        };

        const html = try renderAppPage(allocator, app, aggregates);
        try respondHtml(request, html, .ok);
    }

    pub fn listen(self: Server) !std.Io.net.Server {
        std.log.info("Server started, receiving requests on {s}:{d}", .{ self.host, self.port });
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
            if (std.mem.eql(u8, path, "/admin/createDaily")) return .createDaily;
        },
        else => {},
    }

    return null;
}

fn appKeyFromPath(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/app/")) return null;
    const app_key = path["/app/".len..];
    if (app_key.len == 0) return null;
    return app_key;
}

fn handleLogin(request: *std.http.Server.Request) !void {
    try respondText(request, "ok\n", .ok);
}

fn respondNoContent(request: *std.http.Server.Request) !void {
    try request.respond("", .{
        .status = .no_content,
        .keep_alive = false,
    });
}

fn respondText(request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &text_plain_headers,
    });
}

fn respondBadRequest(request: *std.http.Server.Request) !void {
    try respondText(request, "bad request\n", .bad_request);
}

fn respondNotFound(request: *std.http.Server.Request) !void {
    try respondText(request, "not found\n", .not_found);
}

fn respondInternalError(request: *std.http.Server.Request) !void {
    try respondText(request, "internal server error", .internal_server_error);
}

fn respondHtml(request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &text_html_headers,
    });
}

fn renderPage(allocator: std.mem.Allocator, apps: []const DashboardApp) ![]u8 {
    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>Meioziz</title>
        \\  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" rel="stylesheet">
        \\</head>
        \\<body>
        \\  <header class="border-bottom">
        \\    <div class="container py-3">
        \\      <h1 class="h4 mb-0">Meioziz</h1>
        \\    </div>
        \\  </header>
        \\  <main class="container py-4">
        \\    <h2 class="h5 mb-3">Dashboard</h2>
    );
    if (apps.len == 0) {
        try html.appendSlice(allocator,
            \\    <p class="text-body-secondary mb-0">No active apps configured.</p>
            \\
        );
    } else {
        try html.appendSlice(allocator,
            \\    <div class="row g-3">
            \\
        );

        for (apps) |app| {
            try renderAppCard(&html, allocator, app);
        }

        try html.appendSlice(allocator,
            \\    </div>
            \\
        );
    }

    try html.appendSlice(allocator,
        \\  </main>
        \\  <footer class="border-top">
        \\    <div class="container py-3">
        \\      <a href="https://github.com/monjuik/meioziz">GitHub</a>
        \\    </div>
        \\  </footer>
        \\</body>
        \\</html>
        \\
    );

    return try html.toOwnedSlice(allocator);
}

fn appendEscapedHtml(html: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '&' => try html.appendSlice(allocator, "&amp;"),
            '<' => try html.appendSlice(allocator, "&lt;"),
            '>' => try html.appendSlice(allocator, "&gt;"),
            '"' => try html.appendSlice(allocator, "&quot;"),
            '\'' => try html.appendSlice(allocator, "&#39;"),
            else => try html.append(allocator, char),
        }
    }
}

fn appendJsString(html: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try html.append(allocator, '"');
    for (value) |char| {
        switch (char) {
            '\\' => try html.appendSlice(allocator, "\\\\"),
            '"' => try html.appendSlice(allocator, "\\\""),
            '\n' => try html.appendSlice(allocator, "\\n"),
            '\r' => try html.appendSlice(allocator, "\\r"),
            '\t' => try html.appendSlice(allocator, "\\t"),
            else => try html.append(allocator, char),
        }
    }
    try html.append(allocator, '"');
}

fn renderAppCard(html: *std.ArrayList(u8), allocator: std.mem.Allocator, dashboard_app: DashboardApp) !void {
    try html.appendSlice(allocator,
        \\      <div class="col-12 col-md-6">
        \\        <a class="card text-decoration-none text-body h-100" href="/app/
    );
    try appendEscapedHtml(html, allocator, dashboard_app.app.key);
    try html.appendSlice(allocator,
        \\">
        \\          <div class="card-body">
        \\            <h3 class="h6 card-title mb-2">
    );
    try appendEscapedHtml(html, allocator, dashboard_app.app.name);
    try html.appendSlice(allocator,
        \\</h3>
        \\            <p class="card-text mb-0">
    );

    const count_text = try std.fmt.allocPrint(allocator, "{d}", .{dashboard_app.count});
    try html.appendSlice(allocator, count_text);

    try html.appendSlice(allocator,
        \\ events today</p>
        \\          </div>
        \\        </a>
        \\      </div>
        \\
    );
}

fn renderAppPage(
    allocator: std.mem.Allocator,
    app: *const config.App,
    aggregates: []const db.DailyAggregate,
) ![]u8 {
    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>
    );
    try appendEscapedHtml(&html, allocator, app.name);
    try html.appendSlice(allocator,
        \\ - Meioziz</title>
        \\  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" rel="stylesheet">
        \\  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.5.1/dist/chart.umd.min.js"></script>
        \\</head>
        \\<body>
        \\  <header class="border-bottom">
        \\    <div class="container py-3">
        \\      <a href="/" class="text-decoration-none">Meioziz</a>
        \\    </div>
        \\  </header>
        \\  <main class="container py-4">
        \\    <h1 class="h4 mb-4">
    );
    try appendEscapedHtml(&html, allocator, app.name);
    try html.appendSlice(allocator,
        \\</h1>
        \\
    );

    if (aggregates.len == 0) {
        try html.appendSlice(allocator,
            \\    <p class="text-body-secondary mb-0">No daily aggregates yet.</p>
            \\
        );
    } else {
        var i: usize = 0;
        var group_index: usize = 0;
        while (i < aggregates.len) {
            const code = aggregates[i].code;
            const start = i;
            while (i < aggregates.len and std.mem.eql(u8, aggregates[i].code, code)) {
                i += 1;
            }
            try renderEventCodeBlock(&html, allocator, group_index, code, aggregates[start..i]);
            group_index += 1;
        }
    }

    try html.appendSlice(allocator,
        \\  </main>
        \\  <footer class="border-top">
        \\    <div class="container py-3">
        \\      <a href="https://github.com/monjuik/meioziz">GitHub</a>
        \\    </div>
        \\  </footer>
        \\</body>
        \\</html>
        \\
    );

    return try html.toOwnedSlice(allocator);
}

fn renderEventCodeBlock(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    group_index: usize,
    code: []const u8,
    rows: []const db.DailyAggregate,
) !void {
    try html.appendSlice(allocator,
        \\    <section class="mb-4">
        \\      <h2 class="h5 mb-3">
    );
    try appendEscapedHtml(html, allocator, code);
    try html.appendSlice(allocator,
        \\</h2>
        \\      <div class="row g-3 align-items-start">
        \\        <div class="col-12 col-lg-5">
        \\          <div style="height: 320px;">
        \\            <canvas id="chart-
    );
    try appendInt(html, allocator, @intCast(group_index));
    try html.appendSlice(allocator,
        \\"></canvas>
        \\          </div>
        \\        </div>
        \\        <div class="col-12 col-lg-7">
        \\          <div class="table-responsive">
        \\            <table class="table table-sm align-middle">
        \\              <thead>
        \\                <tr>
        \\                  <th scope="col">Day</th>
        \\                  <th scope="col" class="text-end">Count</th>
        \\                  <th scope="col" class="text-end">Min</th>
        \\                  <th scope="col" class="text-end">Max</th>
        \\                  <th scope="col" class="text-end">Avg</th>
        \\                  <th scope="col" class="text-end">Uniques</th>
        \\                </tr>
        \\              </thead>
        \\              <tbody>
        \\
    );

    for (rows) |row| {
        try renderDailyAggregateRow(html, allocator, row);
    }

    try html.appendSlice(allocator,
        \\              </tbody>
        \\            </table>
        \\          </div>
        \\        </div>
        \\      </div>
        \\      <script>
        \\        new Chart(document.getElementById('chart-
    );
    try appendInt(html, allocator, @intCast(group_index));
    try html.appendSlice(allocator,
        \\'), {
        \\          type: 'line',
        \\          data: {
        \\            labels: [
    );
    var label_index: usize = rows.len;
    while (label_index > 0) {
        label_index -= 1;
        if (label_index != rows.len - 1) {
            try html.appendSlice(allocator, ", ");
        }
        try html.append(allocator, '\'');
        try appendDay(html, allocator, rows[label_index].day);
        try html.append(allocator, '\'');
    }
    try html.appendSlice(allocator,
        \\],
        \\            datasets: [
    );

    try appendIntChartDataset(html, allocator, "Count", rows, .count, false);
    try appendIntChartDataset(html, allocator, "Uniques", rows, .uniques, true);
    try appendIntChartDataset(html, allocator, "Min", rows, .min, true);
    try appendIntChartDataset(html, allocator, "Max", rows, .max, true);
    try appendIntChartDataset(html, allocator, "Avg", rows, .avg, true);

    try html.appendSlice(allocator,
        \\]
        \\          },
        \\
    );

    try html.appendSlice(allocator,
        \\          options: {
        \\            responsive: true,
        \\            maintainAspectRatio: false,
        \\            interaction: {
        \\              intersect: false
        \\            }
        \\          }
        \\        });
        \\      </script>
        \\    </section>
        \\
    );
}

const IntChartMetric = enum {
    count,
    uniques,
    min,
    max,
    avg,
};

fn appendIntChartDataset(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
    rows: []const db.DailyAggregate,
    metric: IntChartMetric,
    comma_prefix: bool,
) !void {
    if (comma_prefix) {
        try html.appendSlice(allocator, ",");
    }

    try html.appendSlice(allocator,
        \\{
        \\              label:
    );
    try appendJsString(html, allocator, label);
    try html.appendSlice(allocator,
        \\,
        \\              data: [
    );

    var value_index: usize = rows.len;
    while (value_index > 0) {
        value_index -= 1;
        if (value_index != rows.len - 1) {
            try html.appendSlice(allocator, ", ");
        }

        const row = rows[value_index];
        switch (metric) {
            .count => try appendInt(html, allocator, row.count),
            .uniques => try appendNullableInt(html, allocator, row.uniques, "null"),
            .min => try appendNullableInt(html, allocator, row.min, "null"),
            .max => try appendNullableInt(html, allocator, row.max, "null"),
            .avg => try appendNullableInt(html, allocator, row.avg, "null"),
        }
    }

    try html.appendSlice(allocator,
        \\],
        \\              cubicInterpolationMode: 'monotone',
        \\              tension: 0.4,
        \\              fill: false
        \\            }
    );
}

fn renderDailyAggregateRow(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    row: db.DailyAggregate,
) !void {
    try html.appendSlice(allocator,
        \\            <tr>
        \\              <td>
    );
    try appendDay(html, allocator, row.day);
    try html.appendSlice(allocator,
        \\</td>
        \\              <td class="text-end">
    );
    try appendInt(html, allocator, row.count);
    try html.appendSlice(allocator,
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, allocator, row.min, "-");
    try html.appendSlice(allocator,
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, allocator, row.max, "-");
    try html.appendSlice(allocator,
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, allocator, row.avg, "-");
    try html.appendSlice(allocator,
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, allocator, row.uniques, "-");
    try html.appendSlice(allocator,
        \\</td>
        \\            </tr>
        \\
    );
}

fn appendInt(html: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    try html.appendSlice(allocator, text);
}

fn appendNullableInt(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: ?i64,
    fallback: []const u8,
) !void {
    if (value) |actual| {
        try appendInt(html, allocator, actual);
    } else {
        try html.appendSlice(allocator, fallback);
    }
}

fn appendDay(html: *std.ArrayList(u8), allocator: std.mem.Allocator, day: i64) !void {
    const days_since_epoch = @divFloor(day, db.day_ms);
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(days_since_epoch) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const text = try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1 },
    );
    try html.appendSlice(allocator, text);
}

// we use UTC
fn startOfDayMillis(now_ms: i64) i64 {
    return @divFloor(now_ms, db.day_ms) * db.day_ms;
}

fn findEventCount(counts: []const db.AppEventCount, app_key: []const u8) i64 {
    for (counts) |count| {
        if (std.mem.eql(u8, count.app_key, app_key)) {
            return count.count;
        }
    }
    return 0;
}

fn lessThanDashboardApp(_: void, left: DashboardApp, right: DashboardApp) bool {
    return std.mem.lessThan(u8, left.app.name, right.app.name);
}

test "match allowed routes" {
    try std.testing.expectEqual(Route.index, matchRoute(.GET, "/"));
    try std.testing.expectEqual(Route.app, matchRoute(.GET, "/app/pairception"));
    try std.testing.expectEqual(Route.event, matchRoute(.POST, "/v1/event"));
    try std.testing.expectEqual(Route.login, matchRoute(.POST, "/login"));
    try std.testing.expectEqual(Route.createDaily, matchRoute(.POST, "/admin/createDaily"));
}

test "reject unknown routes" {
    try std.testing.expectEqual(null, matchRoute(.GET, "/unknown"));
    try std.testing.expectEqual(null, matchRoute(.POST, "/"));
    try std.testing.expectEqual(null, matchRoute(.GET, "/v1/event"));
    try std.testing.expectEqual(null, matchRoute(.PUT, "/v1/event"));
}

test "calculate start of UTC day in milliseconds" {
    const june_29_2026_20_19_utc: i64 = 1782764340000;
    const june_29_2026_start_utc: i64 = 1782691200000;

    try std.testing.expectEqual(
        june_29_2026_start_utc,
        startOfDayMillis(june_29_2026_20_19_utc),
    );
}

test "extract app key from path" {
    try std.testing.expectEqualStrings("pairception", appKeyFromPath("/app/pairception").?);
    try std.testing.expectEqual(null, appKeyFromPath("/app/"));
    try std.testing.expectEqual(null, appKeyFromPath("/unknown"));
}
