-- Add per-user auto-backup scheduling. Idempotent — safe to re-run.
--
-- Two pieces:
--   1. accounts.timezone — IANA timezone name (e.g. 'America/Chicago').
--      Captured on the device and sent on every backupPrefs save so the
--      server can convert the user's local HH:MM to UTC for the cron line.
--   2. pocket_schedules — mirror of the user's auto-backup settings
--      + the systemd unit name that backs them. Lets the admin / UI
--      query "what's scheduled for this user" without parsing systemd
--      unit files.
--
-- Both are kept in sync by the server's PATCH /accounts/<sub> handler.
-- The systemd unit is the executor; the DB row is the readable source
-- of truth.

\set ON_ERROR_STOP on

alter table accounts
  add column if not exists timezone text;

create table if not exists pocket_schedules (
  -- Owning Google account. ON DELETE CASCADE so deleting an account
  -- automatically drops its schedule row (the server also explicitly
  -- tears down the systemd unit on delete — defense in depth).
  sub              text primary key references accounts(sub) on delete cascade,

  -- Mirrors accounts.backup_prefs.enabled. The schedule row only
  -- "exists" in a meaningful way when enabled=true — partial index
  -- below lets the dispatcher query "who's scheduled to fire right
  -- now?" without scanning disabled rows.
  enabled          boolean not null default false,

  -- 'daily' | 'weekly' | 'monthly'. CHECK constraint keeps the
  -- server-side parser from accepting garbage; matches the
  -- BackupFrequency enum on the mobile side.
  frequency        text not null check (frequency in ('daily','weekly','monthly')),

  -- Local hour:minute in the user's timezone (accounts.timezone).
  -- The server converts to UTC before writing OnCalendar= so a 10 PM
  -- CST user fires at 04:00 UTC.
  hour             integer not null check (hour between 0 and 23),
  minute           integer not null check (minute between 0 and 59),

  -- Best-effort projection of when this user's timer should fire next.
  -- Updated every time sync() rewrites the unit. Handy for the admin
  -- "next backup" view; not authoritative (systemd's own state is).
  next_fire_at_utc timestamp with time zone,

  -- Name of the systemd timer unit that backs this row, or NULL when
  -- enabled=false (no unit exists). Useful for `systemctl list-units
  -- --type=timer | grep $(unit_name)` from the admin UI.
  unit_name        text,

  created_at       timestamp with time zone not null default (now() at time zone 'utc'),
  updated_at       timestamp with time zone not null default (now() at time zone 'utc')
);

-- Fast lookup for "who should fire in this minute window?" — the
-- dispatcher's main read path. Partial index (WHERE enabled) keeps it
-- tiny regardless of total account count.
create index if not exists pocket_schedules_enabled_idx
  on pocket_schedules (next_fire_at_utc)
  where enabled;
