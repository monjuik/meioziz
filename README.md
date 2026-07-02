# Meioziz

Tiny privacy-first event stats for indie apps. Zig + SQLite. No user tracking.

Your app sends events to the server, like "a game was finished with the score of 567" or "in-game shop was opened". Meioziz keeps them for a day and calculates daily aggregates. You see them for the previous 28 days.

It's very ecological:
- 2.5 MB self-efficient binary (though, Bootstrap and chart.js are loaded via CDN),
- 2.5 MB RAM with 10k daily events (as SQLite keeps some indexes and cache in memory), 
- less than 1ms for the REST API responses.

## Why am I doing it?

I don't like unknown SDK getting info about the user in my apps. But I would like to know if users are visiting the shop or finishing the game.
So I am building this tool for myself.

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

Valid characters for the `app` and `code`: `a`…`z`, `A`…`Z`, `0`…`9`, `-`, `.`, `_`, ' '.

Strings up to 128 symbols are supported.

## Config

`config.zon` is necessary and is expected in the working directory. Example:

```zig
.{
    .port = 8080,

    .admin_hash = "$2y$12$qBlpx4Y61WRU7bIrhSGdwOyJumNNH/fChk40axsUWbF0NsSTy8uI2",

    .apps = .{
        .{
            .name = "Pairception",
            .key = "pairception",
            .active = true,
        },
    },
}
```

To get a password hash use `htpasswd -bnBC 12 "" 'your-password' | cut -d: -f2`. Note: passwords should not contain URL form special characters: `+`, `%`, `&`, `=`.
`.admin_hash = ""` disables admin login/UI access, but `POST /v1/event` continues working.
