-- Labels from the owner's own actions (DESIGN §7.5): what System 1 should have
-- answered. They feed calibration (M5) and the Decisions view's health figures.

alter table decision add column ticket_id bigint references ticket (id) on delete set null;

create table decision_label (
    id bigint generated always as identity primary key,
    decision_id bigint not null references decision (id) on delete cascade,
    -- The answer the owner's action implies, e.g. {"bot": "researcher"} or {"verdict": "pass"}.
    label jsonb not null,
    -- Whether System 1's own answer matched it.
    agrees boolean not null,
    -- What the owner did: "changed the ticket's bot", "approved the card".
    source text not null,
    created_at timestamptz not null default now()
);

create index decision_label_by_decision on decision_label (decision_id);
