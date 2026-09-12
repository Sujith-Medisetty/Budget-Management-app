# Pocket server — operations

This doc is the operator's view of the VM: what runs on a schedule,
how sign-out / sign-in behaves at the row level, and where to look
when something drifts.

## Scheduled jobs (cron)

The VM runs **2 system-wide timers + N per-user backup timers**:

| Timer unit | Schedule | What it does | Where it lives |
|---|---|---|---|
| `pocket-sweep.timer` | every 6 hours (`*-*-* 0/6:00:00`) | `DELETE FROM envelopes WHERE ttl < NOW()` — the 24h message-handoff rows have outlived their TTL | `server/systemd/pocket-sweep.{service,timer}` → `server/tool/sweep_envelopes_pg.dart` |
| `pocket-budget-rollover.timer` | 1st of every month at 00:05 UTC (`*-*-01 00:05:00`) | Walks every account's `sub`, runs `ensureCurrentMonthBudget` for those with `autoMonthlyBudget=true`, mints `<MonthName> Expenses` rows | `server/systemd/pocket-budget-rollover.{service,timer}` → `server/tool/budget_rollover.dart` |
| `pocket-backup-{sub}.timer` | user's chosen HH:MM (daily / weekly / monthly) | Runs the per-user backup upload to Cloudflare R2 | Generated at runtime by `server/lib/backup_scheduler.dart` when the user enables auto-backup in the Backup screen; one per signed-in user with `backupPrefs.enabled=true` |

`pocket-sweep` and `pocket-budget-rollover` are enabled on every
deploy (`server/tool/deploy.sh` Step 8). The per-user backup timer is
created lazily — the first PATCH `/accounts/{sub}` with
`backupPrefs.enabled=true` runs `BackupScheduler.sync()` which writes
`/etc/systemd/system/pocket-backup-{sub}.{service,timer}` and
`systemctl enable --now`s it.

**Check what's running right now:**

```bash
ssh opc@150.136.83.87 'systemctl list-timers | grep pocket'
```

**Last sweep / rollover log:**

```bash
ssh opc@150.136.83.87 'journalctl -u pocket-sweep --since today'
ssh opc@150.136.83.87 'journalctl -u pocket-budget-rollover --since "1 month ago"'
```

**There is no accounts-table cleanup cron.** The accounts table grows
monotonically until either (a) the user explicitly taps "Delete
account" in Settings (POST `/account/delete`), or (b) FCM reports
`UNREGISTERED` for the user's last device (real app uninstall). Both
go through `deleteAccountCompletely` in
`server/lib/account_cleanup.dart`; nothing else touches the row.

## Sign-out / sign-in: soft-delete with resurrection

As of 2026-09-12, sign-out no longer wipes the row. A user who signs
out and signs back in lands back where they left off — every
preference is preserved. This replaced an old design where sign-out
went through `deleteAccountCompletely` and re-sign-in always landed
on defaults.

### Account lifecycle

```
                ┌──────────────────────────────────────────────────┐
                │                                                  │
   new sub      │   /oauth/exchange                                │
   ─────────────►  case 3: no existing row                        │
                │  → INSERT new AccountRecord (defaults)           │
                │  → fcmTokens={}, revoked=false                  │
                │                                                  │
                │  /oauth/signout                                  │
                │  ─► revoked=true, refresh_token='',              │
                │     fcmTokens={}                                 │
                │     prefs (backupPrefs / budgetPrefs /           │
                │     filterRules / timezone / pocketLabelId) KEPT │
                │                                                  │
   same sub,    │   /oauth/exchange                                │
   re-sign-in   │  case 1: existing.revoked=true                  │
   ◄─────────────  → copyWith(refresh_token, email, lastWatchAt,   │
                │     pocketLabelId, revoked=false)                │
                │     everything else preserved from existing      │
                │                                                  │
   same sub,    │   /oauth/exchange                                │
   token        │  case 2: existing.revoked=false                 │
   refresh      │  → same as case 1 (preserve prefs)               │
                │                                                  │
   user taps    │   POST /account/delete                           │
   "Delete      │  → deleteAccountCompletely()                     │
   account"     │  → wipe Gmail filter + accounts row + filter_rules│
                │                                                  │
   app          │   FCM UNREGISTERED                              │
   uninstall    │  → tokens.put removes FCM token                  │
                │  → if set empties, deleteAccountCompletely()     │
                └──────────────────────────────────────────────────┘
```

### What `revoked=true` gates

- `server/lib/pubsub_handler.dart` — drops the push with a `'revoked'` log line
- `server/lib/filters_sync.dart` — rejects with 403 `'revoked'`

### What's preserved across sign-out / sign-in

| Field | Behavior |
|---|---|
| `refresh_token` | Cleared on sign-out, replaced with new OAuth-issued token on sign-in |
| `fcm_tokens` | Cleared on sign-out (mobile re-registers via `/devices/register` on sign-in) |
| `revoked` | `true` after sign-out, `false` after sign-in |
| `backup_prefs` | **Preserved** (enabled, hour, minute, frequency, notify flags) |
| `budget_prefs` | **Preserved** (`autoMonthlyBudget`) |
| `filter_rules` | **Preserved** (server-side FilterRuleSet JSON) |
| `timezone` | **Preserved** |
| `pocket_label_id` | **Preserved** (Gmail label id we own) |
| `last_watch_at` | Updated on sign-in (we re-register `users.watch`) |
| `last_history_id` | **Preserved** (so Pub/Sub resumes from the right high-water mark) |
| `last_sync_at` | **Preserved** |
| `last_backup_at` | **Preserved** |
| `created_at` | **Preserved** (original signup time) |
| `updated_at` | Set to `now()` on every put |

### Hard-delete paths (the only places `deleteAccountCompletely` is still called)

1. `POST /account/delete` — explicit user request from Settings.
2. FCM `UNREGISTERED` callback — wired in `server/bin/server.dart` line 148; fires when the app is uninstalled.

`/oauth/signout` and `/devices/signout` no longer call it.

## Handlers touched in the soft-delete refactor

- `server/lib/oauth.dart` — `oauthSignout` (soft-delete) and `oauthExchange` (resurrection + same-device token-refresh preservation)
- `server/lib/devices.dart` — `devicesSignout` (no full wipe, ever)
- `server/lib/filters_sync.dart` — added `revoked` guard before `cipher.open(record.refreshToken)`
- `server/bin/server.dart` — wiring updated for the new `oauthSignout` / `devicesSignout` signatures