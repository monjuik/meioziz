# Meioziz specification

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
GET  /admin/createDaily
```

All GET-endpoints are hidden behind the auth. 

`/admin/createDaily` runs daily aggregation of the events in the database. After this raw events are deleted from the DB. NB! This endpoint is for testing or forcing it beacuse of the misconfiguration. Typically the app runs this on its own automatically.

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

Take a look at current entries in raw:

```sql
SELECT
    code,
    COUNT(*) AS events_count
FROM raw
WHERE app = "pairception"
GROUP BY code
ORDER BY events_count DESC, code ASC;
```

---

## Tests with ab

```bash
printf '{"app":"pairception","code":"game-finished"}' > event.json
```

```bash
ab -n 100000 -c 8 -p event.json -T application/json http://127.0.0.1:9000/v1/event
```

## Fuzz testing

```bash
zig build -j1 test -Doptimize=ReleaseSafe --fuzz=100K
```
