-- Routines (PRD B-RTN-01..03; DESIGN §3.5): a prompt a bot runs on a cron schedule,
-- once at a set time, or when its webhook is called.

create table routine (
    id bigint generated always as identity primary key,
    bot_id bigint not null references bot (id),
    name text not null check (length(name) between 1 and 60),
    prompt text not null check (length(prompt) between 1 and 8000),
    -- Five-field cron, read in `timezone`.
    cron text check (cron is null or length(cron) between 9 and 100),
    timezone text not null default 'Europe/London',
    once_at timestamptz,
    -- SHA-256 of the webhook's secret path token; null when it has no webhook.
    hook_hash bytea unique check (hook_hash is null or length(hook_hash) = 32),
    -- Ask System 1 first whether a run is worth it (B-RTN-03).
    preflight boolean not null default false,
    active boolean not null default true,
    -- When the scheduler fires it next; null for webhook-only or a spent one-shot.
    next_at timestamptz,
    last_fired_at timestamptz,
    created_at timestamptz not null default now(),
    check (cron is null or once_at is null)
);

create index routine_due on routine (next_at) where active and next_at is not null;

-- Runs a routine started; counted for the daily cap (PRD Q3).
alter table run add column routine_id bigint references routine (id) on delete set null;

-- Pre-flight decisions are receipted too.
alter table decision drop constraint decision_catalogue_check;
alter table decision add constraint decision_catalogue_check
    check (catalogue in ('triage', 'gate', 'preflight'));
