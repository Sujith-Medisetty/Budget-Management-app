-- Pocket server schema — Oracle VM / Postgres 13.23+
-- Idempotent — safe to re-run on every deploy. NEVER drops existing
-- tables: a deploy that drops accounts/envelopes wipes every signed-in
-- user's refresh token, FCM tokens, filter rules, and backup prefs.
-- New columns go through `migrate_*.sql` with `ADD COLUMN IF NOT EXISTS`.
-- Run as the `postgres` superuser or the `pocket` user with CREATE.
--
-- Layout:
--   accounts      — one row per Google account. Keyed by `sub`. Stores
--                   refresh token (AES-GCM encrypted), email, FCM tokens,
--                   filter rules JSONB, last_history_id, etc.
--   envelopes     — write-ahead copy of incoming Gmail messages. The
--                   `/pubsub/push` handler appends; `/sync?messageId=X`
--                   reads; the mobile app DELETEs after acking.
--   envelopes TTL — 24h, swept by an external cron / pg_cron. Until we
--                   wire cron, run `delete from envelopes where received_at
--                   < now() - interval '24 hours';` once a day.
--
-- Phases 1–3:
--   * `pocket` database exists already (verified during VM bootstrap).
--   * Backup blobs go to local disk (`/var/lib/pocket/backups/`). Phase 4
--     swaps to Cloudflare R2 via S3-compatible API.

\set ON_ERROR_STOP on

create table if not exists accounts (
  sub             text primary key,

  -- Encrypted with config.tokenEncryptionKey (AES-GCM). Blank/null is
  -- permitted only for accounts mid-revoke — sign-in always writes a
  -- fresh token.
  refresh_token   bytea       not null,

  email           text        not null,

  -- All watch-related state lives on the row so a single SELECT /accounts/{sub}
  -- hydrates everything in one round trip.
  last_watch_at      timestamp with time zone not null default (now() at time zone 'utc'),
  last_history_id    text,
  last_sync_at       timestamp with time zone,
  last_backup_at     timestamp with time zone,

  -- FCM device tokens. Plain text array (we don't encrypt these — they're
  -- opaque ids Google's API uses as routing keys, so encryption adds
  -- nothing).
  fcm_tokens      text[]      not null default '{}',

  -- Set true by /oauth/signout so `accounts/<sub>` lookups can return
  -- a tombstone instead of leaking the encrypted refresh token.
  revoked         boolean     not null default false,

  -- Per-account label id for our "Pocket/Keep" Gmail label. Created on
  -- first sign-in. Null for legacy accounts that pre-date the
  -- label-scheme — pubsub_handler self-heals them on the next push.
  pocket_label_id text,

  -- User's backup prefs as a JSONB blob. Keep the shape in sync with
  -- server/lib/token_store.dart::BackupPrefs.
  backup_prefs    jsonb       not null default '{}'::jsonb,

  -- User's budget prefs as a JSONB blob. Currently just the
  -- `autoMonthlyBudget` toggle — see
  -- server/lib/token_store.dart::BudgetPrefs. Defaults to OFF
  -- (auto-create is opt-in). The PATCH /accounts/<sub> handler
  -- runs `ensureCurrentMonthBudget` as a side-effect when the
  -- toggle flips ON for a user who has no current-month budget
  -- row, so toggling ON is a one-tap "make me a budget for this
  -- month" affordance. Toggling OFF is intentionally non-
  -- destructive — see BudgetPrefs for the rationale.
  budget_prefs    jsonb       not null default '{"autoMonthlyBudget": false}'::jsonb,

  -- FilterRuleSet serialized to JSON string (matches the Firestore
  -- shape exactly, so migration of older accounts is a copy job). Null
  -- = no rules configured.
  filter_rules    text,

  -- Bookkeeping. Created-at is set on first OAuth exchange, updated-at
  -- is bumped on every PATCH.
  created_at      timestamp with time zone not null default (now() at time zone 'utc'),
  updated_at      timestamp with time zone not null default (now() at time zone 'utc')
);

-- Reverse lookup used by Pub/Sub handler — keyed by email because
-- Pub/Sub payloads carry `emailAddress`, not `sub`.
create unique index if not exists accounts_email_idx on accounts (lower(email));

create table if not exists envelopes (
  -- Gmail messageId. Primary key — same id space the Gmail API uses.
  message_id      text primary key,

  -- Owning account. We keep the FK explicit (not nullable) so orphan
  -- rows from a buggy sign-out surface as referential errors instead
  -- of silently living forever.
  sub             text not null references accounts(sub) on delete cascade,

  -- Envelope metadata for in-app display before the body is fetched.
  -- The full body is fetched by the mobile app via /sync when needed
  -- (FCM payload is truncated at ~4 KB; envelopes here have a 100 KB
  -- cap to keep DB rows reasonable).
  from_addr       text,
  subject         text,
  body            text,
  received_at     timestamp with time zone not null default (now() at time zone 'utc'),
  ttl             timestamp with time zone not null default (now() at time zone 'utc' + interval '24 hours')
);

create index if not exists envelopes_sub_idx on envelopes (sub);
create index if not exists envelopes_ttl_idx on envelopes (ttl);

-- Server-side auto-created monthly budgets. The phone's local SQLite
-- is the editor (source of truth for user-visible state), but the
-- cron that runs on the 1st of every month writes here so a user who
-- doesn't sign in mid-rollover still gets their next month's budget
-- created. The phone fetches these via `GET /budgets?month=YYYY-MM`
-- after sign-in and inserts them into its local SQLite.
--
-- `id` is a UUID-ish string the server mints on insert; we don't
-- reuse the mobile-side int autoincrement because the server has no
-- way to predict what the next local id would be on the phone.
-- `source='auto'` rows are the cron / sign-in / rollover creations;
-- `source='manual'` rows are user-created (rare — the phone normally
-- creates manually without telling the server, but a future
-- "share budget" feature might).
create table if not exists budgets (
  sub             text not null references accounts(sub) on delete cascade,

  id              text not null,
  name            text not null,
  amount          numeric(12,2) not null default 0,
  period          text not null default 'monthly'
                    check (period in ('daily','weekly','monthly','yearly','custom')),
  start_date      date not null,
  end_date        date not null,
  active          boolean not null default false,
  source          text not null default 'auto'
                    check (source in ('auto','manual')),

  -- Same shape as the SQLite alerts config on the phone. Stored so a
  -- future restore-from-server path doesn't lose them.
  alert_every     boolean,
  alert_thresholds text,

  created_at      timestamp with time zone not null default (now() at time zone 'utc'),

  primary key (sub, id)
);

-- "Show me auto-created budgets for this user in this month" is the
-- hot read path (mobile calls it on every sign-in).
create index if not exists budgets_sub_start_idx
  on budgets (sub, start_date);

-- The cron rolls forward looking for "user has no budget starting on
-- the 1st of next month yet" — partial index keeps it cheap even as
-- the table grows.
create index if not exists budgets_sub_active_idx
  on budgets (sub) where active;
