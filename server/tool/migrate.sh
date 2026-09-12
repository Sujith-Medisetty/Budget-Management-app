#!/usr/bin/env bash
# One-off: apply tool/migrate_schedules.sql to the live Postgres
# instance. Idempotent — re-running is a no-op.
#
# Run from the VM:
#   sudo bash /opt/pocket/server/tool/migrate.sh
#
# Reads the same PG_* vars /opt/pocket/server/.env carries, so the
# database / user / password match what pocket-server already talks to.
# The .env is `set -a`-sourced so `PGPASSWORD` picks up PG_PASSWORD
# without exporting each var by hand.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/pocket/server/.env}"
SQL_FILE="${SQL_FILE:-/opt/pocket/server/tool/migrate_schedules.sql}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "migrate: cannot read $ENV_FILE" >&2
  exit 1
fi
if [[ ! -r "$SQL_FILE" ]]; then
  echo "migrate: cannot read $SQL_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${PG_USER:-}" || -z "${PG_DB:-}" || -z "${PG_HOST:-}" ]]; then
  echo "migrate: PG_USER / PG_DB / PG_HOST must be set in $ENV_FILE" >&2
  exit 1
fi

echo "migrate: applying $SQL_FILE to $PG_DB on $PG_HOST (user=$PG_USER)"
PGPASSWORD="${PG_PASSWORD:-}" psql \
  --host="$PG_HOST" \
  --port="${PG_PORT:-5432}" \
  --username="$PG_USER" \
  --dbname="$PG_DB" \
  --variable=ON_ERROR_STOP=1 \
  --file="$SQL_FILE"
echo "migrate: done"
