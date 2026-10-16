-- System 1 receipts (DESIGN §7.6): every decision Laya was asked for, what it
-- answered, and what OrphusBot did with it. The full state is kept 30 days for
-- labelling (§7.5), then only its hash.

create table decision (
    id bigint generated always as identity primary key,
    catalogue text not null check (catalogue in ('triage', 'gate')),
    state_hash bytea not null check (length(state_hash) = 32),
    state text,
    -- Null when it abstained (not configured, too slow, failed).
    answers jsonb,
    abstained boolean not null,
    -- The confidence the answer needed to be acted on.
    threshold real not null,
    -- The confidence it had, for the answer that mattered.
    confidence real,
    model text,
    latency_ms integer not null check (latency_ms >= 0),
    -- What OrphusBot did, in words: "Sent to Researcher", "Asked the owner".
    outcome text not null,
    run_id bigint references run (id),
    tool_call_id text,
    created_at timestamptz not null default now()
);

create index decision_recent on decision (created_at desc);

-- The effect ledger can now record System 1 as the decider of a reversible call.
alter table effect drop constraint effect_decided_by_check;
alter table effect add constraint effect_decided_by_check
    check (decided_by in ('rule', 'ledger', 'owner', 'system1'));
