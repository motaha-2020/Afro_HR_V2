#!/usr/bin/env bash
# Applies every migration, then the seed, then the rule tests — in order, in
# one transaction per file, aborting on the first error.
set -euo pipefail
cd "$(dirname "$0")"

PSQL="${PSQL:-psql}"
DB_URL="${DB_URL:-postgresql://afro:afro_dev_only@localhost:55432/afro_hr}"

run() {
    echo "── $1"
    "$PSQL" "$DB_URL" -v ON_ERROR_STOP=1 --single-transaction -q -f "$1"
}

case "${1:-all}" in
  reset)
    "$PSQL" "$DB_URL" -v ON_ERROR_STOP=1 -q -c \
      "DROP SCHEMA IF EXISTS platform, identity, org, core_hr, workforce, personnel, compensation, config, integration, audit CASCADE;"
    echo "schemas dropped"
    ;;& 
  all|reset)
    for f in migrations/V*.sql; do run "$f"; done
    for f in seed/S*.sql;      do run "$f"; done
    echo "schema + seed applied"
    ;;
  test)
    for f in tests/T*.sql; do run "$f"; done
    ;;
  migrate)
    for f in migrations/V*.sql; do run "$f"; done
    ;;
esac
