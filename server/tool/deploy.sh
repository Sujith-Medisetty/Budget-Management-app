#!/usr/bin/env bash
# Pocket server — push + deploy to Oracle VM (Oracle Linux 9 ARM64).
# Run from your Mac. Idempotent.
#
# Usage:
#   ./tool/deploy.sh
#
# Reads:
#   - VM_HOST         default: 150.136.83.87
#   - VM_USER         default: opc
#   - VM_SSH_KEY      default: ~/Documents/Oracle VM public and private keys/ssh-key-2026-09-09.key
#   - SERVER_PORT     default: 8080
#   - POCKET_DB_PASSWORD  default: pocket-prod-2026
#   - WEB_CLIENT_ID   default: empty
#   - WEB_CLIENT_SECRET  default: empty
#
# What it does:
#   1. Ensures Postgres `pocket` DB + user exist (CREATE if absent).
#   2. Sets a known password for `pocket`.
#   3. Opens firewalld 80 + 443 for HTTPS.
#   4. rsyncs the repo to /opt/pocket on the VM.
#   5. Runs `dart pub get` on the VM.
#   6. Runs the schema migration (base + per-user schedules).
#   7. Writes server .env (preserves TOKEN_ENCRYPTION_KEY + API_TOKEN_SECRET + R2_* across runs).
#   8. Installs systemd units: pocket-server (root), pocket-sweep oneshot + timer.
#   9. Starts (or restarts) pocket-server + enables pocket-sweep.timer.
#  10. Smoke-tests /health via curl over SSH.
#
# Re-runs preserve TOKEN_ENCRYPTION_KEY + API_TOKEN_SECRET (rotating would
# invalidate stored refresh tokens).

set -euo pipefail

# === Configuration =========================================================

VM_HOST="${VM_HOST:-150.136.83.87}"
VM_USER="${VM_USER:-opc}"
# Use a symlinked key without spaces — rsync's sh-passing of -e args loses
# spaces, so we mirror the actual key to ~/.ssh/pocket-vm-key.
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/pocket-vm-key}"
SERVER_PORT="${SERVER_PORT:-8080}"
POCKET_DB_USER="${POCKET_DB_USER:-pocket}"
POCKET_DB_NAME="${POCKET_DB_NAME:-pocket}"
POCKET_DB_PASSWORD="${POCKET_DB_PASSWORD:-pocket-prod-2026}"

REPO_DIR=/opt/pocket
SECRETS_DIR=/opt/pocket/secrets

# Repo root on this Mac (one level up from server/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# === Helpers ==============================================================

log()  { printf '\033[1;36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

ssh_vm() {
  ssh -i "$VM_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
    "$VM_USER@$VM_HOST" "$@"
}

ssh_vm_sudo() {
  ssh -i "$VM_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
    "$VM_USER@$VM_HOST" "sudo $@"
}

scp_vm() {
  scp -i "$VM_SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "$1" "$VM_USER@$VM_HOST:$2"
}

# === Step 1: Postgres DB + user ============================================

ensure_pg() {
  log "Step 1/10: ensuring Postgres user/db"
  ssh_vm_sudo "bash -s" <<'REMOTE'
set -euo pipefail
sudo -u postgres psql -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pocket') THEN
    CREATE ROLE pocket LOGIN PASSWORD 'pocket-prod-2026';
  ELSE
    ALTER ROLE pocket WITH PASSWORD 'pocket-prod-2026';
  END IF;
END
$$;
SQL
EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='pocket'")
if [[ "$EXISTS" != "1" ]]; then
  sudo -u postgres createdb -O pocket pocket
  echo "[deploy]  created database pocket"
else
  echo "[deploy]  database pocket already exists"
fi
# Patch pg_hba to use md5 for 127.0.0.1 if it's currently ident.
HBA=/var/lib/pgsql/data/pg_hba.conf
if grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32\s+ident' "$HBA"; then
  echo "[deploy]  patching pg_hba.conf (ident -> md5)"
  cp "$HBA" "$HBA.bak.$(date +%s)"
  sed -i 's|^host  *all  *all  *127\.0\.0\.1/32  *ident|host  all  all  127.0.0.1/32  md5|' "$HBA"
  sed -i 's|^host  *all  *all  *::1/128  *ident|host  all  all  ::1/128  md5|' "$HBA" || true
  systemctl reload postgresql
fi
PGPASSWORD='pocket-prod-2026' psql -h 127.0.0.1 -U pocket -d pocket -c 'SELECT 1 AS up'
REMOTE
  log "  ✓ postgres ready"
}

# === Step 2: Firewalld ports 80 + 443 ======================================

open_http_ports() {
  log "Step 2/10: opening firewalld 80 + 443"
  ssh_vm_sudo "firewall-cmd --permanent --add-port=80/tcp" >/dev/null
  ssh_vm_sudo "firewall-cmd --permanent --add-port=443/tcp" >/dev/null
  ssh_vm_sudo "firewall-cmd --reload" >/dev/null
  ssh_vm_sudo "firewall-cmd --list-ports"
  log "  ✓ ports open"
}

# === Step 3: rsync repo ====================================================

rsync_repo() {
  log "Step 3/10: rsyncing repo → $VM_HOST:$REPO_DIR"
  # Create dirs with correct ownership in one shot (install respects owner).
  ssh_vm_sudo "install -d -o $VM_USER -g $VM_USER -m 750 $REPO_DIR $SECRETS_DIR /var/lib/pocket/backups" 2>&1 | head -5
  rsync -az --delete \
    --exclude '.git/' \
    --exclude '**/build/' \
    --exclude '**/.dart_tool/' \
    --exclude 'server/.env' \
    --exclude '.DS_Store' \
    --exclude 'secrets/' \
    -e 'ssh -i '"$VM_SSH_KEY"' -o StrictHostKeyChecking=accept-new' \
    "$REPO_ROOT/" "$VM_USER@$VM_HOST:$REPO_DIR/"
  log "  ✓ rsync done"
}

# === Step 4: dart pub get ==================================================

pub_get() {
  log "Step 4/10: dart pub get on VM"
  ssh_vm "cd $REPO_DIR/server && /usr/local/bin/dart pub get --offline 2>&1 || /usr/local/bin/dart pub get" 2>&1 | tail -10
  log "  ✓ deps resolved"
}

# === Step 5: schema =======================================================

run_schema() {
  log "Step 5/10: applying Postgres schema"
  # Safety net: snapshot accounts + envelopes row count before the
  # schema runs. If either drops afterwards, abort — the schema file
  # is supposed to be idempotent (CREATE TABLE IF NOT EXISTS) and a
  # DROP-only regression would otherwise nuke every signed-in user's
  # refresh token + filter rules + backup prefs silently.
  local before
  before=$(ssh_vm "PGPASSWORD='$POCKET_DB_PASSWORD' psql -h 127.0.0.1 -U $POCKET_DB_USER -d $POCKET_DB_NAME -tAc 'SELECT (SELECT count(*) FROM accounts) || \" \" || (SELECT count(*) FROM envelopes)'" 2>/dev/null || echo "0 0")
  local beforeAccounts=${before%% *}
  local beforeEnvelopes=${before##* }

  ssh_vm "PGPASSWORD='$POCKET_DB_PASSWORD' psql -h 127.0.0.1 -U $POCKET_DB_USER -d $POCKET_DB_NAME -v ON_ERROR_STOP=1 -f $REPO_DIR/server/tool/schema_postgres.sql" 2>&1 | tail -5
  log "  ✓ base schema applied"
  # Idempotent — adds accounts.timezone + pocket_schedules. Re-runs are
  # no-ops (every CREATE / ALTER is IF NOT EXISTS).
  ssh_vm "PGPASSWORD='$POCKET_DB_PASSWORD' psql -h 127.0.0.1 -U $POCKET_DB_USER -d $POCKET_DB_NAME -v ON_ERROR_STOP=1 -f $REPO_DIR/server/tool/migrate_schedules.sql" 2>&1 | tail -5
  log "  ✓ schedule schema applied"
  # Idempotent — adds accounts.budget_prefs + budgets table. Same
  # IF NOT EXISTS pattern; re-running the deploy on a VM that already
  # has these is a no-op. schema_postgres.sql already bakes these in
  # for fresh installs, so this migration exists only to bring older
  # prod VMs forward.
  ssh_vm "PGPASSWORD='$POCKET_DB_PASSWORD' psql -h 127.0.0.1 -U $POCKET_DB_USER -d $POCKET_DB_NAME -v ON_ERROR_STOP=1 -f $REPO_DIR/server/tool/migrate_budgets.sql" 2>&1 | tail -5
  log "  ✓ budget schema applied"
  # Flip the JSONB column DEFAULT for budget_prefs from
  # '{"autoMonthlyBudget": true}' to '{...,"autoMonthlyBudget":
  # false}'. Idempotent — re-runs hit an already-mutated default.
  # Only affects future INSERTs that don't pass budget_prefs; existing
  # rows preserve their stored value.
  ssh_vm "PGPASSWORD='$POCKET_DB_PASSWORD' psql -h 127.0.0.1 -U $POCKET_DB_USER -d $POCKET_DB_NAME -v ON_ERROR_STOP=1 -f $REPO_DIR/server/tool/migrate_budget_default_off.sql" 2>&1 | tail -5
  log "  ✓ budget-prefs default set to OFF"

  local after
  after=$(ssh_vm "PGPASSWORD='$POCKET_DB_PASSWORD' psql -h 127.0.0.1 -U $POCKET_DB_USER -d $POCKET_DB_NAME -tAc 'SELECT (SELECT count(*) FROM accounts) || \" \" || (SELECT count(*) FROM envelopes)'" 2>/dev/null || echo "0 0")
  local afterAccounts=${after%% *}
  local afterEnvelopes=${after##* }
  if [[ "$afterAccounts" -lt "$beforeAccounts" || "$afterEnvelopes" -lt "$beforeEnvelopes" ]]; then
    fail "schema run DELETED rows: accounts $beforeAccounts→$afterAccounts, envelopes $beforeEnvelopes→$afterEnvelopes — aborting deploy. The schema file is supposed to be idempotent; check for accidental DROP TABLE."
  fi
  log "  ✓ row counts preserved (accounts=$afterAccounts, envelopes=$afterEnvelopes)"
}

# === Step 6: write server .env ============================================

write_env() {
  log "Step 6/10: writing server .env (preserving existing secrets)"
  ssh_vm "bash -s" <<REMOTE
set -euo pipefail
ENV_FILE=$REPO_DIR/server/.env
mkdir -p "\$(dirname \$ENV_FILE)"
ENC_KEY=""
API_SECRET=""
WEB_ID=""
WEB_SECRET=""
R2_ENDPOINT_=""
R2_BUCKET_=""
R2_ACCESS_KEY_ID_=""
R2_SECRET_ACCESS_KEY_=""
if [[ -f "\$ENV_FILE" ]]; then
  ENC_KEY=\$(grep -E '^TOKEN_ENCRYPTION_KEY=' "\$ENV_FILE" | cut -d= -f2- || true)
  API_SECRET=\$(grep -E '^API_TOKEN_SECRET=' "\$ENV_FILE" | cut -d= -f2- || true)
  WEB_ID=\$(grep -E '^WEB_CLIENT_ID=' "\$ENV_FILE" | cut -d= -f2- || true)
  WEB_SECRET=\$(grep -E '^WEB_CLIENT_SECRET=' "\$ENV_FILE" | cut -d= -f2- || true)
  R2_ENDPOINT_=\$(grep -E '^R2_ENDPOINT=' "\$ENV_FILE" | cut -d= -f2- || true)
  R2_BUCKET_=\$(grep -E '^R2_BUCKET=' "\$ENV_FILE" | cut -d= -f2- || true)
  R2_ACCESS_KEY_ID_=\$(grep -E '^R2_ACCESS_KEY_ID=' "\$ENV_FILE" | cut -d= -f2- || true)
  R2_SECRET_ACCESS_KEY_=\$(grep -E '^R2_SECRET_ACCESS_KEY=' "\$ENV_FILE" | cut -d= -f2- || true)
fi
ENC_KEY="\${ENC_KEY:-\$(openssl rand -hex 32)}"
API_SECRET="\${API_SECRET:-\$(openssl rand -hex 32)}"
# Fall back to the local Mac .env (where the real credentials live
# from gcloud auth) before resorting to the placeholder. Otherwise a
# fresh VM with no prior .env gets placeholder values and sign-in
# 502s with `invalid_client` from Google.
WEB_ID="\${WEB_ID:-${WEB_CLIENT_ID:-PLACEHOLDER-replace-me-with-real-google-oauth-web-client-id.apps.googleusercontent.com}}"
WEB_SECRET="\${WEB_SECRET:-${WEB_CLIENT_SECRET:-PLACEHOLDER-replace-me-with-real-google-oauth-web-client-secret}}"
# R2: pull from the local server/.env if the VM didn't have them set.
# Without this, any deploy onto a VM that previously had R2_* would
# clobber the creds (the old write_env only preserved TOKEN_/API_/WEB_
# vars), and the next server boot would fail fast with "R2 creds
# missing". See project_pocket_r2_backup_store.md.
LOCAL_ENV="$REPO_DIR/server/.env"
if [[ -z "\$R2_ENDPOINT_" && -f "\$LOCAL_ENV" ]]; then
  R2_ENDPOINT_=\$(grep -E '^R2_ENDPOINT=' "\$LOCAL_ENV" | cut -d= -f2- || true)
  R2_BUCKET_=\$(grep -E '^R2_BUCKET=' "\$LOCAL_ENV" | cut -d= -f2- || true)
  R2_ACCESS_KEY_ID_=\$(grep -E '^R2_ACCESS_KEY_ID=' "\$LOCAL_ENV" | cut -d= -f2- || true)
  R2_SECRET_ACCESS_KEY_=\$(grep -E '^R2_SECRET_ACCESS_KEY=' "\$LOCAL_ENV" | cut -d= -f2- || true)
fi

cat > "\$ENV_FILE" <<ENV
PORT=$SERVER_PORT
PG_HOST=127.0.0.1
PG_PORT=5432
PG_DB=$POCKET_DB_NAME
PG_USER=$POCKET_DB_USER
PG_PASSWORD=$POCKET_DB_PASSWORD
TOKEN_ENCRYPTION_KEY=\$ENC_KEY
API_TOKEN_SECRET=\$API_SECRET
GCP_PROJECT=pocket-mail-sync
PUBSUB_TOPIC=projects/pocket-mail-sync/topics/gmail-history
PUBSUB_AUDIENCE=https://pocket.karmacode.online/pubsub/push
WEB_CLIENT_ID=\$WEB_ID
WEB_CLIENT_SECRET=\$WEB_SECRET
FCM_PROJECT_ID=pocket-mail-sync
FCM_SERVICE_ACCOUNT_JSON=$SECRETS_DIR/fcm-service-account.json
R2_ENDPOINT=\$R2_ENDPOINT_
R2_BUCKET=\$R2_BUCKET_
R2_ACCESS_KEY_ID=\$R2_ACCESS_KEY_ID_
R2_SECRET_ACCESS_KEY=\$R2_SECRET_ACCESS_KEY_
ENV

chmod 600 "\$ENV_FILE"
echo "[deploy]  .env written"
REMOTE
  log "  ✓ .env in place"
}

# === Step 7: secrets dir ==================================================

ensure_secrets() {
  log "Step 7/10: ensuring secrets dir + FCM JSON"
  # Create the secrets dir on the VM so systemd's ReadWritePaths mount doesn't
  # fail with "No such file or directory" before dart even starts.
  ssh_vm_sudo "install -d -o $VM_USER -g $VM_USER -m 750 $SECRETS_DIR" 2>&1 | head -3
  ssh_vm "test -f $SECRETS_DIR/fcm-service-account.json" 2>/dev/null \
    && log "  ✓ FCM JSON present" \
    || warn "  ⚠ FCM service-account JSON missing at $SECRETS_DIR/fcm-service-account.json — FCM will fail until you scp it there"
}

# === Step 8: systemd units ================================================

write_systemd_unit() {
  log "Step 8/10: writing systemd units"
  # Dart reads .env itself via dotenv() at startup — no compile-time defines
  # needed. We just exec dart run from the server dir.
  #
  # User=root (not $VM_USER): the BackupScheduler writes per-user
  # `pocket-backup-<sub>.{service,timer}` units to /etc/systemd/system
  # and runs `systemctl enable --now <unit>` on every PATCH /accounts.
  # That requires write access to /etc/systemd/system + the ability to
  # talk to systemd, neither of which an opc-scoped service has. The
  # rest of the VM treats pocket-server as the trusted operator anyway
  # (it's the only writer of /etc/systemd/system here), and pocket-sweep
  # is already root for the same reason.
  ssh_vm_sudo "bash -s" <<REMOTE
set -euo pipefail
install -m 644 $REPO_DIR/server/systemd/pocket-server.service /etc/systemd/system/pocket-server.service
install -m 644 $REPO_DIR/server/systemd/pocket-sweep.service /etc/systemd/system/pocket-sweep.service
install -m 644 $REPO_DIR/server/systemd/pocket-sweep.timer /etc/systemd/system/pocket-sweep.timer
install -m 644 $REPO_DIR/server/systemd/pocket-budget-rollover.service /etc/systemd/system/pocket-budget-rollover.service
install -m 644 $REPO_DIR/server/systemd/pocket-budget-rollover.timer /etc/systemd/system/pocket-budget-rollover.timer
systemctl daemon-reload
systemctl enable pocket-server.service
systemctl enable pocket-sweep.timer
systemctl enable pocket-budget-rollover.timer
echo "[deploy]  units installed"
REMOTE
  log "  ✓ pocket-server.service + pocket-sweep.{service,timer} + pocket-budget-rollover.{service,timer} installed"
}

# === Step 9: start + smoke ================================================

start_and_smoke() {
  log "Step 9/10: restarting + smoke-testing"
  ssh_vm_sudo "systemctl restart pocket-server.service"
  # Dart cold start + Postgres pool warm-up + systemd notify: budget 12s.
  # Was 3s before the per-user backup scheduler landed; the new code
  # path is heavier at boot and the previous 3s was racy on slow
  # boots.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 1
    body=$(ssh_vm "curl -fsS --max-time 2 http://127.0.0.1:$SERVER_PORT/health 2>/dev/null" || true)
    [[ "$body" == "ok" ]] && break
  done
  ssh_vm_sudo "systemctl status pocket-server.service --no-pager | head -15"

  if [[ "$body" == "ok" ]]; then
    log "  ✓ /health = ok"
  else
    fail "/health probe failed after 12s — last body: ${body:-<no response>}"
  fi
}

# === Step 10: Oracle Cloud Security List reminder ========================

remind_oracle_firewall() {
  log "Step 10/10: post-deploy reminder"
  cat <<'NEXT'

[next steps]
1. Oracle Cloud Security List: open TCP 80 + 443 ingress to this VM
   (Networking → Virtual Cloud Networks → your VCN → Subnet → Security List
    → Add Ingress Rules: 0.0.0.0/0 : 80/tcp, 0.0.0.0/0 : 443/tcp)
2. DNS: point pocket.karmacode.online → 150.136.83.87 (A record)
3. Caddyfile: drop a Caddy config for pocket.karmacode.online that
   reverse-proxies :443 → http://127.0.0.1:8080 with auto-TLS.
4. FCM JSON: scp your service-account JSON to $SECRETS_DIR on the VM.
5. Pub/Sub: re-point subscription to https://pocket.karmacode.online/pubsub/push
NEXT
}

# === Main ================================================================

ensure_pg
open_http_ports
rsync_repo
pub_get
run_schema
write_env
ensure_secrets
write_systemd_unit
start_and_smoke
remind_oracle_firewall

log "DONE — pocket-server is live on port $SERVER_PORT"
