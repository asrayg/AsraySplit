#!/usr/bin/env bash
# Runs every migration and pgTAP test against a throwaway local PostgreSQL cluster.
#
#   scripts/db-test.sh            # uses Homebrew/PATH postgres + pgTAP, no Docker needed
#   DB_TEST_KEEP=1 scripts/db-test.sh   # leave the cluster running for debugging
#
# CI uses the real Supabase stack instead (`supabase start && supabase test db`); this script
# exists so the database suite also runs on machines without Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${DB_TEST_DIR:-$ROOT/.build/pgtest}"
PORT="${DB_TEST_PORT:-54329}"
DB=asray_split_test

rm -rf "$WORK" && mkdir -p "$WORK"
initdb -D "$WORK/data" -A trust -U postgres --no-locale -E UTF8 >"$WORK/initdb.log"
pg_ctl -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses='' -c wal_level=logical" -l "$WORK/server.log" -w start >/dev/null
cleanup() { [[ "${DB_TEST_KEEP:-0}" == 1 ]] || pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

export PGOPTIONS="-c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$WORK" -p "$PORT" -U postgres)
"${PSQL[@]}" -d postgres -c "create database $DB"
# Same default search_path as hosted Supabase.
"${PSQL[@]}" -d postgres -c "alter database $DB set search_path = \"\$user\", public, extensions"
"${PSQL[@]}" -d "$DB" -f "$ROOT/supabase/tests/shim/supabase_shim.sql" >/dev/null

for migration in "$ROOT"/supabase/migrations/*.sql; do
  echo "migrate $(basename "$migration")"
  "${PSQL[@]}" -d "$DB" -f "$migration" >/dev/null
done

if [[ -n "${DB_FIXTURES_OUT:-}" ]]; then
  mkdir -p "$DB_FIXTURES_OUT"
  "${PSQL[@]}" -d "$DB" -v outdir="$DB_FIXTURES_OUT" -f "$ROOT/scripts/fixtures.sql" >/dev/null
  echo "fixtures written to $DB_FIXTURES_OUT"
fi

failed=0
for test in "$ROOT"/supabase/tests/*_test.sql; do
  out="$("${PSQL[@]}" -d "$DB" -t -A -f "$test" 2>&1)" || true
  if grep -qE '^not ok|ERROR|Looks like you' <<<"$out"; then
    echo "FAIL $(basename "$test")"; echo "$out" | grep -E '^not ok|ERROR|#|Looks like' | head -40
    failed=1
  else
    echo "ok   $(basename "$test") ($(grep -c '^ok' <<<"$out") assertions)"
  fi
done
exit $failed
