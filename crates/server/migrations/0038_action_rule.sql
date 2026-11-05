-- "Always allow" for one exact action (DESIGN §11.6, D-059). Phone taps that could
-- commit skip the per-tool rules (D-045), so an owner's "always" on such a card
-- allows that same action again (same tool, same input) and nothing else.
create table action_rule (
    tool text not null check (length(tool) > 0),
    input jsonb not null,
    created_at timestamptz not null default now(),
    primary key (tool, input)
);
