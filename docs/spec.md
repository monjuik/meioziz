# Meioziz specification

## Why am I doing it?

I don't like unknown SDK getting info about the user in my apps. But I would like to know if users are visiting the shop or finishing the game.
So I am building this tool for myself.

## How am I doing it?

KISS: as simple as possible. External dependencies only if they are really needed and inevitable.

One self-efficient excutable file.

I like Zig. Zig be it.

## HTTP Endpoints

```
POST /v1/event
POST /login
GET  /
GET  /app/:code
```


## UI

Minimalistic Bootstrap and chart.js for the charts.


## DB Tables

As project has so few tables, I called them in very compact way:
- `raw` for raw events,
- `daily` for daily aggregates,
- `migration` is internal, for SQL migration scripts.

See `src/db.zig`.

Useful commands to work with the db:
```bash
sqlite3 'file:meioziz.db?mode=ro'
sqlite> .headers on
sqlite> .mode box
sqlite> .tables
sqlite> SELECT * FROM migration;
```

---

## Tests with ab

`printf '{"app":"pairception","code":"game-finished"}' > event.json`

`ab -n 100000 -c 8 -p event.json -T application/json http://127.0.0.1:9000/v1/event`
