-- Flip the default value of accounts.budget_prefs from `true` to
-- `false`. Idempotent — safe to re-run.
--
-- The previous default was ON so first-time sign-ups got the
-- auto-create flow without an extra PATCH. Now auto-create is
-- opt-in: new rows default to OFF, and the user explicitly flips the
-- toggle from the Settings screen to enable it. Existing rows keep
-- whatever value they already had — only the column DEFAULT (used
-- when a new row omits budget_prefs entirely) is changed.
--
-- `ALTER COLUMN ... SET DEFAULT` only affects future INSERTs that
-- don't supply the column. SELECTs that look at already-persisted
-- rows see whatever value was previously written. So a user who had
-- the toggle ON before this migration keeps it ON after; a user who
-- had it OFF (or never set it) gets OFF on subsequent saves that
-- don't explicitly pass `autoMonthlyBudget`.

\set ON_ERROR_STOP on

alter table accounts
  alter column budget_prefs
    set default '{"autoMonthlyBudget": false}'::jsonb;
