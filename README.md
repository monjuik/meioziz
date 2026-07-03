# Meioziz

Tiny privacy-first event stats for indie apps. Zig + SQLite. No user tracking.

Your app sends events to the server, like "a game was finished with the score of 567" or "in-game shop was opened". Meioziz keeps them for a day and calculates daily aggregates. You see them for the previous 28 days.

It's very ecological:
- self-efficient binary (though, Bootstrap and chart.js are loaded via CDN),
- 2.5 MB RAM with 10k daily events (as SQLite keeps some indexes and cache in memory), 
- less than 1ms for the REST API responses.

## Why am I doing it?

I don't like unknown SDK getting info about the user in my apps. But I would like to know if users are visiting the shop or finishing the game.
So I am building this tool for myself.

## What's in this name?

This app is very tiny, the events are tiny – as amoeba's poke. Meiosis is a their reproduction.

## Binaries

Prebuilt binaries are provided for Linux x86_64, other platforms can build from source with Zig 0.16.0.

## How to use

`zig build run`

## How to test

`zig build test`

## How to build

`zig build -Doptimize=ReleaseSafe`

  - Linux amd64: `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe`
  - macOS Apple Silicon: `zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe`

  ---

## API

External app sends events via `POST /v1/event`.

OpenAPI schema: [`docs/openapi.yaml`](docs/openapi.yaml).

### Basic event

```json
{
  "app": "pairception",
  "code": "daily-reward"
}
```

### Event with some numeric value

```json
{
  "app": "pairception",
  "code": "game-finished",
  "value": 100
}
```
`value` is integer and optional.

### Event with installId

```json
{
  "app": "pairception",
  "code": "installed",
  "installId": "019f285e-72a0-7f47-bf5e-0ede086fb46f"
}
```
`installId` is optional. Meioziz uses it to calculate unique installs in daily aggregates.

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

To get a password hash use `htpasswd -bnBC 12 "" 'your-password' | cut -d: -f2`.
`.admin_hash = ""` disables admin login/UI access, but `POST /v1/event` continues working.

## Deployment

Meioziz is intentionally small and should be deployed behind a reverse proxy such as nginx. The built-in HTTP server handles one accepted connection at a time. A reverse proxy should terminate public HTTP traffic, enforce request timeouts and body size limits, and then forward requests to Meioziz on localhost.

Recommended nginx settings:

```nginx
server {
    listen 80;
    server_name meioziz.example.com;

    client_header_timeout 5s;
    client_body_timeout 10s;
    client_max_body_size 16k;

    location / {
        proxy_pass http://127.0.0.1:8123;
        proxy_http_version 1.1;
        proxy_set_header Connection close;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 2s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;

        proxy_request_buffering on;
    }
}
```
`client_header_timeout` protects the upstream server from clients that open a connection but do not finish sending HTTP headers. `client_body_timeout` and `client_max_body_size` match the small event payloads expected by Meioziz.
`proxy_request_buffering on` lets nginx receive the request body before forwarding it to the application.
