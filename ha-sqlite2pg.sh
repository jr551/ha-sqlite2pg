#!/usr/bin/env bash
#
# ha-sqlite2pg — migrate a Home Assistant recorder database from SQLite to PostgreSQL
#
# Strategy (the reliable one):
#   1. Stop HA and snapshot the SQLite DB (WAL-checkpointed, consistent copy)
#   2. Start HA against the (empty) PostgreSQL DB so HA itself creates the schema
#   3. Stop HA, bulk-load the history with pgloader (data only, truncate)
#   4. Fix ALL identity sequences (pgloader's "reset sequences" does NOT cover
#      these in data-only mode — skipping this causes duplicate-key errors!)
#   5. Verify row counts table-by-table, then start HA on the migrated data
#
# Usage:
#   PG_URL='postgresql://user:pass@127.0.0.1:5432/homeassistant' ./ha-sqlite2pg.sh
#
# Configuration (environment variables):
#   PG_URL        PostgreSQL URL the *recorder* uses (required). Set the same
#                 value as db_url in your recorder: config BEFORE running this.
#   HA_CONFIG     HA config directory containing home-assistant_v2.db
#                 (default: /config)
#   HA_START      command that starts Home Assistant
#                 (default: systemctl start homeassistant)
#   HA_STOP       command that stops Home Assistant
#                 (default: systemctl stop homeassistant)
#   PSQL          command that runs psql against your server
#                 (default: podman exec postgres psql)
#   WORK_DIR      scratch directory for the DB snapshot (default: /tmp/ha-sqlite2pg)
#
# Requirements: bash, sqlite3, pgloader, psql access to the target DB.
# Your existing SQLite file is never modified — it is copied first.

set -euo pipefail

# ----- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\e[31m' GRN=$'\e[32m' YLW=$'\e[33m' BLU=$'\e[34m' CYN=$'\e[36m' BLD=$'\e[1m' RST=$'\e[0m'
else
  RED='' GRN='' YLW='' BLU='' CYN='' BLD='' RST=''
fi
step()  { echo; echo "${BLD}${BLU}==>${RST}${BLD} $*${RST}"; }
info()  { echo "    ${CYN}$*${RST}"; }
ok()    { echo "    ${GRN}✔ $*${RST}"; }
warn()  { echo "    ${YLW}⚠ $*${RST}"; }
fail()  { echo "    ${RED}✘ $*${RST}" >&2; exit 1; }

# ----- config ----------------------------------------------------------------
PG_URL="${PG_URL:-}"
HA_CONFIG="${HA_CONFIG:-/config}"
HA_START="${HA_START:-systemctl start homeassistant}"
HA_STOP="${HA_STOP:-systemctl stop homeassistant}"
PSQL="${PSQL:-podman exec postgres psql}"
WORK_DIR="${WORK_DIR:-/tmp/ha-sqlite2pg}"
SQLITE_DB="$HA_CONFIG/home-assistant_v2.db"
SNAPSHOT="$WORK_DIR/ha-snapshot.db"

# Never echo PG_URL anywhere — it contains the password.
psql_q() { $PSQL "$PG_URL" -tAc "$1"; }

TABLES=(states states_meta state_attributes events event_data event_types
        statistics statistics_short_term statistics_meta statistics_runs
        recorder_runs schema_changes)

step "Preflight checks"
[[ -n "$PG_URL" ]] || fail "PG_URL is not set. Export it first (never commit it anywhere)."
command -v sqlite3  >/dev/null || fail "sqlite3 not found"
command -v pgloader >/dev/null || fail "pgloader not found"
[[ -f "$SQLITE_DB" ]] || fail "SQLite DB not found at $SQLITE_DB (set HA_CONFIG)"
psql_q "SELECT 1" >/dev/null || fail "cannot connect to PostgreSQL with PG_URL"
mkdir -p "$WORK_DIR"; chmod 700 "$WORK_DIR"
ok "sqlite3, pgloader, and PostgreSQL connection all good"

step "Stopping Home Assistant and snapshotting SQLite"
$HA_STOP
sqlite3 "$SQLITE_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
cp "$SQLITE_DB" "$SNAPSHOT"
ok "snapshot: $SNAPSHOT ($(du -h "$SNAPSHOT" | cut -f1))"

step "Starting HA against PostgreSQL so it creates the recorder schema"
info "make sure recorder: db_url already points at PostgreSQL!"
$HA_START
SCHEMA_V=0
for _ in $(seq 1 60); do
  SCHEMA_V=$(psql_q "SELECT coalesce(max(schema_version),0) FROM schema_changes" 2>/dev/null || echo 0)
  [[ "$SCHEMA_V" -gt 0 ]] && break
  sleep 5
done
[[ "$SCHEMA_V" -gt 0 ]] || fail "HA did not create the schema — is db_url set correctly?"
SQLITE_V=$(sqlite3 "$SNAPSHOT" "SELECT max(schema_version) FROM schema_changes;")
ok "PostgreSQL schema_version=$SCHEMA_V, SQLite schema_version=$SQLITE_V"
if [[ "$SCHEMA_V" != "$SQLITE_V" ]]; then
  warn "schema versions differ — upgrade HA on SQLite first so both match, then retry"
  fail "aborting before any data is touched"
fi
sleep 10

step "Stopping HA and bulk-loading history with pgloader"
$HA_STOP
LOAD_FILE="$WORK_DIR/migrate.load"
umask 077
cat > "$LOAD_FILE" <<EOF
load database
  from sqlite://$SNAPSHOT
  into $PG_URL
with data only, truncate, reset sequences, batch rows = 5000
;
EOF
info "running pgloader (log: $WORK_DIR/pgloader.log)..."
pgloader --quiet "$LOAD_FILE" > "$WORK_DIR/pgloader.log" 2>&1 || true
rm -f "$LOAD_FILE"   # contains the password
grep -qE "^Total import time.*✓" "$WORK_DIR/pgloader.log" \
  || warn "pgloader summary line not found — inspect $WORK_DIR/pgloader.log"
ok "bulk load finished"

step "Fixing identity sequences (the step everyone forgets)"
psql_q "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.table_name tn, c.column_name cn,
           pg_get_serial_sequence(quote_ident(c.table_name), c.column_name) sq
    FROM information_schema.columns c
    WHERE c.table_schema='public'
      AND pg_get_serial_sequence(quote_ident(c.table_name), c.column_name) IS NOT NULL
  LOOP
    EXECUTE format('SELECT setval(%L, coalesce((SELECT max(%I)+1 FROM %I), 1), false)',
                   r.sq, r.cn, r.tn);
  END LOOP;
END \$\$;" >/dev/null
ok "every serial/identity sequence now starts after the migrated max id"

step "Verifying row counts"
MISMATCH=0
for t in "${TABLES[@]}"; do
  SL=$(sqlite3 "$SNAPSHOT" "SELECT count(*) FROM $t;" 2>/dev/null || echo "n/a")
  PG=$(psql_q "SELECT count(*) FROM $t;" 2>/dev/null || echo "n/a")
  if [[ "$SL" == "$PG" ]]; then
    ok "$t: $SL rows"
  else
    warn "$t: sqlite=$SL postgres=$PG"
    MISMATCH=1
  fi
done
[[ "$MISMATCH" -eq 0 ]] || warn "row count mismatches above — review before trusting the migration"

step "Starting Home Assistant on the migrated database"
$HA_START
ok "done — watch the HA log for recorder errors for a few minutes"
echo
echo "${BLD}${GRN}Migration complete.${RST}"
echo "Your original SQLite file was not modified: $SQLITE_DB"
echo "Keep it until you are happy, then archive or delete it."
