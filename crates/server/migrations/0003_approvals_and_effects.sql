-- Approval rules and the effect ledger (DESIGN §3.4, §7.4; PRD B-RUN-04).
--
-- Every tool call that isn't read-only gets a ledger row per attempt. If a run
-- is resumed and the bot repeats a call that already completed, the server
-- blocks it and hands back the earlier result; a call that was approved but
-- never reported done is "uncertain" and goes to the owner.

create type rule_effect as enum ('allow', 'deny');

create table approval_rule (
    tool text primary key check (length(tool) > 0),
    effect rule_effect not null,
    created_at timestamptz not null default now()
);

create type effect_state as enum ('pending', 'approved', 'denied', 'completed', 'failed');

create table effect (
    id bigint generated always as identity primary key,
    run_id bigint not null references run (id),
    fence bigint not null,
    tool_call_id text not null,
    tool text not null,
    input jsonb not null,
    state effect_state not null,
    -- Who decided: 'rule', 'ledger' or 'owner'. Null while pending.
    decided_by text check (decided_by in ('rule', 'ledger', 'owner')),
    result text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (run_id, fence, tool_call_id),
    check ((state = 'pending') = (decided_by is null))
);

create index effect_by_run_tool on effect (run_id, tool);
