const std = @import("std");
const config = @import("config.zig");
const event = @import("event.zig");

const bootstrap_css =
    \\  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css" rel="stylesheet">
;

/// Rows must have their configured names supplied and are rendered in the supplied order.
pub fn renderIndex(allocator: std.mem.Allocator, rows: []const event.AppRow) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const html = &output.writer;

    try html.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>Meioziz</title>
        \\
    ++ bootstrap_css ++ "\n" ++
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
    if (rows.len == 0) {
        try html.writeAll(
            \\    <p class="text-body-secondary mb-0">No active apps configured.</p>
            \\
        );
    } else {
        try html.writeAll(
            \\    <div class="row g-3">
            \\
        );

        for (rows) |row| {
            try renderAppCard(html, row);
        }

        try html.writeAll(
            \\    </div>
            \\
        );
    }

    try html.writeAll(
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

    return output.toOwnedSlice();
}

fn appendEscapedHtml(html: *std.Io.Writer, value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '&' => try html.writeAll("&amp;"),
            '<' => try html.writeAll("&lt;"),
            '>' => try html.writeAll("&gt;"),
            '"' => try html.writeAll("&quot;"),
            '\'' => try html.writeAll("&#39;"),
            else => try html.writeByte(char),
        }
    }
}

fn appendJsString(html: *std.Io.Writer, value: []const u8) !void {
    try html.writeByte('"');
    for (value) |char| {
        switch (char) {
            '\\' => try html.writeAll("\\\\"),
            '"' => try html.writeAll("\\\""),
            '\n' => try html.writeAll("\\n"),
            '\r' => try html.writeAll("\\r"),
            '\t' => try html.writeAll("\\t"),
            else => try html.writeByte(char),
        }
    }
    try html.writeByte('"');
}

fn renderAppCard(html: *std.Io.Writer, row: event.AppRow) !void {
    try html.writeAll(
        \\      <div class="col-12 col-md-6">
        \\        <a class="card text-decoration-none text-body h-100" href="/app/
    );
    try appendEscapedHtml(html, row.app_key);
    try html.writeAll(
        \\">
        \\          <div class="card-body">
        \\            <h3 class="h6 card-title mb-2">
    );
    try appendEscapedHtml(html, row.name);
    try html.writeAll(
        \\</h3>
        \\            <p class="card-text mb-0">
    );

    try html.print("{d}", .{row.count});

    try html.writeAll(
        \\ events today</p>
        \\          </div>
        \\        </a>
        \\      </div>
        \\
    );
}

/// Aggregates must be ordered by code ascending, then day descending.
pub fn renderApp(
    allocator: std.mem.Allocator,
    app: *const config.App,
    aggregates: []const event.DailyAggregate,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const html = &output.writer;

    try html.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>
    );
    try appendEscapedHtml(html, app.name);
    try html.writeAll(
        \\ - Meioziz</title>
        \\
    ++ bootstrap_css ++ "\n" ++
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
    try appendEscapedHtml(html, app.name);
    try html.writeAll(
        \\</h1>
        \\
    );

    if (aggregates.len == 0) {
        try html.writeAll(
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
            try renderEventCodeBlock(html, group_index, code, aggregates[start..i]);
            group_index += 1;
        }
    }

    try html.writeAll(
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

    return output.toOwnedSlice();
}

fn renderEventCodeBlock(
    html: *std.Io.Writer,
    group_index: usize,
    code: []const u8,
    rows: []const event.DailyAggregate,
) !void {
    try html.writeAll(
        \\    <section class="mb-4">
        \\      <h2 class="h5 mb-3">
    );
    try appendEscapedHtml(html, code);
    try html.writeAll(
        \\</h2>
        \\      <div class="row g-3 align-items-start">
        \\        <div class="col-12 col-lg-5">
        \\          <div style="height: 320px;">
        \\            <canvas id="chart-
    );
    try html.print("{d}", .{group_index});
    try html.writeAll(
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

    for (rows) |*row| {
        try renderDailyAggregateRow(html, row);
    }

    try html.writeAll(
        \\              </tbody>
        \\            </table>
        \\          </div>
        \\        </div>
        \\      </div>
        \\      <script>
        \\        new Chart(document.getElementById('chart-
    );
    try html.print("{d}", .{group_index});
    try html.writeAll(
        \\'), {
        \\          type: 'line',
        \\          data: {
        \\            labels: [
    );
    var label_index: usize = rows.len;
    while (label_index > 0) {
        label_index -= 1;
        if (label_index != rows.len - 1) {
            try html.writeAll(", ");
        }
        try html.writeByte('\'');
        try appendDay(html, rows[label_index].day);
        try html.writeByte('\'');
    }
    try html.writeAll(
        \\],
        \\            datasets: [
    );

    try appendIntChartDataset(html, "Count", rows, .count, false);
    try appendIntChartDataset(html, "Uniques", rows, .uniques, true);
    try appendIntChartDataset(html, "Min", rows, .min, true);
    try appendIntChartDataset(html, "Max", rows, .max, true);
    try appendIntChartDataset(html, "Avg", rows, .avg, true);

    try html.writeAll(
        \\]
        \\          },
        \\
    );

    try html.writeAll(
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
    html: *std.Io.Writer,
    label: []const u8,
    rows: []const event.DailyAggregate,
    metric: IntChartMetric,
    comma_prefix: bool,
) !void {
    if (comma_prefix) {
        try html.writeAll(",");
    }

    try html.writeAll(
        \\{
        \\              label:
    );
    try appendJsString(html, label);
    try html.writeAll(
        \\,
        \\              data: [
    );

    var value_index: usize = rows.len;
    while (value_index > 0) {
        value_index -= 1;
        if (value_index != rows.len - 1) {
            try html.writeAll(", ");
        }

        const row = &rows[value_index];
        switch (metric) {
            .count => try html.print("{d}", .{row.count}),
            .uniques => try appendNullableInt(html, row.uniques, "null"),
            .min => try appendNullableInt(html, row.min, "null"),
            .max => try appendNullableInt(html, row.max, "null"),
            .avg => try appendNullableInt(html, row.avg, "null"),
        }
    }

    try html.writeAll(
        \\],
        \\              cubicInterpolationMode: 'monotone',
        \\              tension: 0.4,
        \\              fill: false
        \\            }
    );
}

fn renderDailyAggregateRow(html: *std.Io.Writer, row: *const event.DailyAggregate) !void {
    try html.writeAll(
        \\            <tr>
        \\              <td>
    );
    try appendDay(html, row.day);
    try html.writeAll(
        \\</td>
        \\              <td class="text-end">
    );
    try html.print("{d}", .{row.count});

    try html.writeAll(
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, row.min, "-");
    try html.writeAll(
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, row.max, "-");
    try html.writeAll(
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, row.avg, "-");
    try html.writeAll(
        \\</td>
        \\              <td class="text-end">
    );
    try appendNullableInt(html, row.uniques, "-");
    try html.writeAll(
        \\</td>
        \\            </tr>
        \\
    );
}

fn appendNullableInt(html: *std.Io.Writer, value: ?i64, fallback: []const u8) !void {
    if (value) |actual| {
        try html.print("{d}", .{actual});
    } else {
        try html.writeAll(fallback);
    }
}

fn appendDay(html: *std.Io.Writer, day: i64) !void {
    const days_since_epoch = @divFloor(day, (std.time.s_per_day * std.time.ms_per_s));
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(days_since_epoch) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try html.print(
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1 },
    );
}

pub fn renderLogin() []const u8 {
    return
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>Login - Meioziz</title>
    \\
    ++ bootstrap_css ++ "\n" ++
        \\</head>
        \\<body>
        \\  <main class="container py-5" style="max-width: 28rem">
        \\    <h1 class="h3 mb-4">Login</h1>
        \\    <form method="post" action="/login">
        \\      <div class="mb-3">
        \\        <label class="form-label" for="username">Username</label>
        \\        <input class="form-control" id="username" name="username" autocomplete="username" autofocus>
        \\      </div>
        \\      <div class="mb-3">
        \\        <label class="form-label" for="password">Password</label>
        \\        <input class="form-control" id="password" name="password" type="password" autocomplete="current-password">
        \\      </div>
        \\      <button class="btn btn-primary" type="submit">Login</button>
        \\    </form>
        \\  </main>
        \\</body>
        \\</html>
    ;
}

test "render prepared dashboard rows and escape HTML" {
    const rows = [_]event.AppRow{
        .{ .app_key = "a", .count = 0, .name = "Alpha & <Friends>" },
        .{ .app_key = "z", .count = 7, .name = "Zulu" },
    };
    const body = try renderIndex(std.testing.allocator, &rows);
    defer std.testing.allocator.free(body);
    const alpha = std.mem.indexOf(u8, body, "Alpha &amp; &lt;Friends&gt;").?;
    const zulu = std.mem.indexOf(u8, body, "Zulu").?;
    try std.testing.expect(alpha < zulu);
    try std.testing.expect(std.mem.indexOf(u8, body, "href=\"/app/a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0 events today") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "7 events today") != null);
}

test "render empty pages and login" {
    const dashboard = try renderIndex(std.testing.allocator, &.{});
    defer std.testing.allocator.free(dashboard);
    try std.testing.expect(std.mem.indexOf(u8, dashboard, "No active apps configured.") != null);
    const app: config.App = .{ .key = "example", .name = "Example" };
    const body = try renderApp(std.testing.allocator, &app, &.{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "No daily aggregates yet.") != null);
    try std.testing.expect(std.mem.indexOf(u8, renderLogin(), "method=\"post\" action=\"/login\"") != null);
}

test "render aggregate groups with descending table days and ascending chart days" {
    const app: config.App = .{ .key = "example", .name = "Example" };
    const rows = [_]event.DailyAggregate{
        .{ .day = 1782777600000, .code = "a", .count = 2, .uniques = 1, .min = 10, .max = 20, .avg = 15 },
        .{ .day = 1782691200000, .code = "a", .count = 1, .uniques = null, .min = null, .max = null, .avg = null },
        .{ .day = 1782691200000, .code = "b", .count = 3, .uniques = null, .min = null, .max = null, .avg = null },
    };
    const body = try renderApp(std.testing.allocator, &app, &rows);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026-06-30").? < std.mem.indexOf(u8, body, "2026-06-29").?);
    try std.testing.expect(std.mem.indexOf(u8, body, "'2026-06-29', '2026-06-30'") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[1, 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[null, 10]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ">-</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"chart-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"chart-1\"") != null);
}
