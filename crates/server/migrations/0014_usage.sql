-- What each assistant message used (PRD M4 quota tracker), as its provider reported it.
create table usage (
    id bigint generated always as identity primary key,
    run_id bigint references run (id) on delete set null,
    bot text not null,
    provider text not null,
    model text not null,
    input bigint not null check (input >= 0),
    output bigint not null check (output >= 0),
    cache_read bigint not null check (cache_read >= 0),
    cache_write bigint not null check (cache_write >= 0),
    -- US dollars × 1,000,000; subscriptions report what the call would have cost.
    cost_micros bigint not null check (cost_micros >= 0),
    created_at timestamptz not null default now()
);

create index usage_recent on usage (created_at);
