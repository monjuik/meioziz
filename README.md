# Meioziz

Tiny privacy-first event stats for indie apps. Zig + SQLite. No user tracking.

Your app sends events to the server, like "a game was finished with the score of 567" or "in-game shop was opened". Meioziz keeps them for a day and calculates daily aggregates. You see them for the previous 28 days.

It's very ecological:
- 2.5 MB self-efficient binary (though, Bootstrap and chart.js are loaded via CDN),
- 2.5 MB RAM with 10k daily events (as SQLite keeps some indexes and cache in memory), 
- less than 1ms for the REST API responses.

## What's in this name?

This app is very tiny, the events are tiny – as amoeba's poke. Meiosis is a their reproduction.

## How to use

`zig build run`

## How to test

`zig build test`

## How to build

`zig build -Doptimize=ReleaseSafe`

---

## API

External app sends events via `POST /v1/event`. Example:

```json
{
  "app": "pairception",
  "code": "game-finished",
  "value": 100
}
```
`value` is integer and optional.
`installId` is optional.

Valid characters for the `app` and `code`: 'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', ' '.

Strings up to 128 symbols are supported.

## Config

`config.zon` in the working directory. Example:

```zig
.{
    .port = 8080,

    .admin_hash = "pbkdf2-sha256:...",

    .apps = .{
        .{
            .name = "Pairception",
            .key = "pairception",
            .active = true,
        },
    },
}
```
