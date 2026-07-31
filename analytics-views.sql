-- Analytics views over the Home Assistant recorder schema (v53)
-- All read-only; live in their own schema so recorder migrations never touch them.
CREATE SCHEMA IF NOT EXISTS analytics;

-- 1. Latest state of every entity, with age
CREATE OR REPLACE VIEW analytics.current_states AS
SELECT sm.entity_id,
       s.state,
       to_timestamp(s.last_updated_ts) AT TIME ZONE 'Europe/London' AS last_updated,
       now() - to_timestamp(s.last_updated_ts) AS age
FROM states s
JOIN states_meta sm USING (metadata_id)
WHERE s.state_id IN (SELECT max(state_id) FROM states GROUP BY metadata_id);

-- 2. Chattiest entities in the last 24 hours
CREATE OR REPLACE VIEW analytics.chatty_entities_24h AS
SELECT sm.entity_id,
       count(*) AS state_changes,
       round(count(*) / 24.0, 1) AS per_hour
FROM states s
JOIN states_meta sm USING (metadata_id)
WHERE s.last_updated_ts > extract(epoch FROM now() - interval '24 hours')
GROUP BY sm.entity_id
ORDER BY state_changes DESC;

-- 3. Daily energy per kWh statistic (energy dashboard source data)
CREATE OR REPLACE VIEW analytics.daily_energy AS
SELECT m.statistic_id,
       (to_timestamp(s.start_ts) AT TIME ZONE 'Europe/London')::date AS day,
       round((max(s.sum) - min(s.sum))::numeric, 3) AS kwh
FROM statistics s
JOIN statistics_meta m ON m.id = s.metadata_id
WHERE m.unit_of_measurement = 'kWh' AND s.sum IS NOT NULL
GROUP BY m.statistic_id, day
ORDER BY day DESC, kwh DESC;

-- 4. Daily temperature min/mean/max per sensor
CREATE OR REPLACE VIEW analytics.daily_temperature AS
SELECT m.statistic_id,
       (to_timestamp(s.start_ts) AT TIME ZONE 'Europe/London')::date AS day,
       round(min(s.min)::numeric, 1) AS t_min,
       round(avg(s.mean)::numeric, 1) AS t_mean,
       round(max(s.max)::numeric, 1) AS t_max
FROM statistics s
JOIN statistics_meta m ON m.id = s.metadata_id
WHERE m.unit_of_measurement IN ('°C', '°F')
GROUP BY m.statistic_id, day
ORDER BY day DESC, m.statistic_id;

-- 5. Activity heatmap: state changes by weekday x hour (last 30 days)
CREATE OR REPLACE VIEW analytics.activity_heatmap AS
SELECT to_char(to_timestamp(last_updated_ts) AT TIME ZONE 'Europe/London', 'Dy') AS weekday,
       extract(isodow FROM to_timestamp(last_updated_ts) AT TIME ZONE 'Europe/London')::int AS dow,
       extract(hour FROM to_timestamp(last_updated_ts) AT TIME ZONE 'Europe/London')::int AS hour,
       count(*) AS state_changes
FROM states
WHERE last_updated_ts > extract(epoch FROM now() - interval '30 days')
GROUP BY 1, 2, 3
ORDER BY dow, hour;

-- 6. Unreliable entities: most time spent unavailable/unknown (last 7 days)
CREATE OR REPLACE VIEW analytics.unreliable_entities_7d AS
SELECT sm.entity_id,
       count(*) AS bad_intervals,
       count(*) FILTER (WHERE s.state = 'unavailable') AS unavailable,
       count(*) FILTER (WHERE s.state = 'unknown') AS unknown
FROM states s
JOIN states_meta sm USING (metadata_id)
WHERE s.state IN ('unavailable', 'unknown')
  AND s.last_updated_ts > extract(epoch FROM now() - interval '7 days')
GROUP BY sm.entity_id
ORDER BY bad_intervals DESC;

-- 7. Event volume per type per day
CREATE OR REPLACE VIEW analytics.event_volume AS
SELECT et.event_type,
       (to_timestamp(e.time_fired_ts) AT TIME ZONE 'Europe/London')::date AS day,
       count(*) AS events
FROM events e
JOIN event_types et USING (event_type_id)
GROUP BY et.event_type, day
ORDER BY day DESC, events DESC;

-- 8. Database growth: size and rows per recorder table
CREATE OR REPLACE VIEW analytics.db_size AS
SELECT c.relname AS "table",
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       c.reltuples::bigint AS approx_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

-- 9. Long-term retention summary: oldest data per source, now that purging is off
CREATE OR REPLACE VIEW analytics.retention_summary AS
SELECT 'states' AS source,
       to_timestamp(min(last_updated_ts))::date AS oldest,
       to_timestamp(max(last_updated_ts))::date AS newest,
       count(*) AS rows
FROM states
UNION ALL
SELECT 'events', to_timestamp(min(time_fired_ts))::date, to_timestamp(max(time_fired_ts))::date, count(*) FROM events
UNION ALL
SELECT 'statistics (hourly)', to_timestamp(min(start_ts))::date, to_timestamp(max(start_ts))::date, count(*) FROM statistics;
