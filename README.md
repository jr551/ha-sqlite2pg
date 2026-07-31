# ha-sqlite2pg

Migrate a **Home Assistant recorder database from SQLite to PostgreSQL** — history,
events, and long-term statistics included — in one colourful, verbose script.

Battle-tested on a real install: 2M+ rows / 300 MB migrated in ~2.5 minutes with
zero row-count mismatches, on HA 2026.7 (recorder schema v53) and PostgreSQL 17.

## Why this script

Most guides run pgloader and call it a day. Two things then bite you:

1. **Schema drift** — pgloader-created schemas don't match what HA expects.
   This script lets *Home Assistant itself* create the PostgreSQL schema, then
   loads data only.
2. **Broken sequences** — in data-only mode pgloader does **not** reset
   PostgreSQL identity sequences, so the recorder immediately hits
   `duplicate key value violates unique constraint` errors. This script fixes
   every sequence to `max(id)+1` automatically.

It also WAL-checkpoints SQLite before copying, aborts if the SQLite and
PostgreSQL schema versions differ, verifies row counts table-by-table, and
never modifies your original SQLite file.

## Prerequisites

- A running PostgreSQL server with an empty database and a dedicated user
- `recorder:` in `configuration.yaml` already pointing at PostgreSQL:

  ```yaml
  recorder:
    db_url: !secret recorder_db_url
  ```

- `sqlite3` and `pgloader` installed wherever the script runs
- A way to start/stop Home Assistant from that host

## Usage

```bash
export PG_URL='postgresql://hass:SECRET@127.0.0.1:5432/homeassistant'

HA_CONFIG=/path/to/ha/config \
HA_STOP='systemctl stop homeassistant' \
HA_START='systemctl start homeassistant' \
PSQL='podman exec postgres psql' \
./ha-sqlite2pg.sh
```

All settings are environment variables — see the header of the script for the
full list and defaults. `PSQL` just needs to be *some* command that accepts a
connection URL, e.g. plain `psql`, `docker exec postgres psql`, or
`podman exec postgres psql`.

Expect a few minutes of Home Assistant downtime (two restarts plus the bulk
load — roughly 5 minutes per GB of SQLite database).

## After migrating

- Watch the HA log for a few minutes. A **single**
  `compile_missing_statistics` duplicate-key error right after the first start
  is harmless (HA re-derives a statistics window that was migrated); it should
  not repeat.
- HA's built-in backup no longer covers your database — schedule `pg_dump`.
- Keep the untouched SQLite file until you're confident, then archive it.

## Bonus: analytics views

[`analytics-views.sql`](analytics-views.sql) adds a read-only `analytics`
schema with handy views over the recorder data: current entity states,
chattiest entities, daily energy per kWh sensor, daily temperature min/mean/max,
a weekday×hour activity heatmap, flaky-entity ranking, event volume, table
sizes, and a retention summary.

```bash
psql "$PG_URL" -f analytics-views.sql
psql "$PG_URL" -c 'SELECT * FROM analytics.daily_energy LIMIT 10;'
```

The views assume `Europe/London` for day boundaries — search-and-replace the
timezone if yours differs.

## License

MIT
