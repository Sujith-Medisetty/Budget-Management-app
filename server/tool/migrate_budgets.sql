-- Add auto-monthly-budget feature. Idempotent — safe to re-run.
--
-- Two pieces:
--   1. accounts.budget_prefs — JSONB blob. Currently just the
--      `autoMonthlyBudget` boolean. Default TRUE so first-time
--      sign-ups get the auto-create flow immediately. Existing users
--      get it ON too — flipping it OFF is the user's choice, not
--      something the migration should silently override.
--   2. budgets — server-side table for auto-created monthly budgets.
--      The phone's local SQLite is the editor (source of truth for
--      user-visible state), but the cron writes here so offline users
--      still get next month's budget created. Phone reads via
--      `GET /budgets?month=YYYY-MM` on sign-in.

\set ON_ERROR_STOP on

-- 1. budget_prefs column. Default TRUE per the design rationale in
-- schema_postgres.sql. `if not exists` lets this migration be re-run
-- without "column already exists" errors.
alter table accounts
  add column if not exists budget_prefs jsonb
    not null default '{"autoMonthlyBudget": true}'::jsonb;

-- 2. budgets table. See schema_postgres.sql for column rationale.
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
  alert_every     boolean,
  alert_thresholds text,
  created_at      timestamp with time zone not null default (now() at time zone 'utc'),
  primary key (sub, id)
);

create index if not exists budgets_sub_start_idx
  on budgets (sub, start_date);

create index if not exists budgets_sub_active_idx
  on budgets (sub) where active;
