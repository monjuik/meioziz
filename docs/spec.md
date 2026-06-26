# Meioziz specification

## Why am I doing it?

I don't like unknown SDK getting info about the user in my apps. But I would like to know if users are visiting the shop or finishing the game.
So I am building this tool for myself.

## How am I doing it?

KISS: as simple as possible. External dependencies only if they are really needed and inevitable.

One self-efficient excutable file.

I like Zig. Zig be it.

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
`installID` is optional.

## HTTP Endpoints

```
POST /v1/event
POST /login
GET  /
GET  /app/:code
```


## UI

Minimalistic Bootstrap and vanilla JS.


## Config

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

## DB Tables

### Raw

- id
- received
- app
- code
- value

### Daily

- id
- day
- app
- event
- count
- min
- max
- sum

### Migration

- id
- file
- executed
