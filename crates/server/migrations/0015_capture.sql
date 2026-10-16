-- Ambient capture (DESIGN §10, PRD B-CAP-01..07): hands-free text in windows,
-- mined into proposals the owner accepts or dismisses. No audio is ever stored;
-- window text is deleted after the retention period; an accepted proposal keeps
-- only its fields and a short quote.

create table capture_window (
    id bigint generated always as identity primary key,
    device_id text not null references device (id) on delete cascade,
    -- "speaker: words" lines; null once deleted after retention.
    text text,
    -- open → closed → mined (or failed); closed waits for a node to extract.
    state text not null default 'open' check (state in ('open', 'closed', 'mined', 'failed')),
    opened_at timestamptz not null default now(),
    last_at timestamptz not null default now(),
    closed_at timestamptz
);

create index capture_window_open on capture_window (device_id) where state = 'open';

create table proposal (
    id bigint generated always as identity primary key,
    window_id bigint references capture_window (id) on delete set null,
    kind text not null check (kind in ('commitment', 'task', 'appointment', 'follow-up', 'idea', 'remember')),
    title text not null check (length(title) between 1 and 200),
    detail text not null default '' check (length(detail) <= 1000),
    who text not null default '' check (length(who) <= 100),
    due text not null default '' check (length(due) <= 100),
    quote text not null default '' check (length(quote) <= 200),
    state text not null default 'proposed' check (state in ('proposed', 'accepted', 'dismissed')),
    -- What accepting made.
    ticket_id bigint references ticket (id) on delete set null,
    created_at timestamptz not null default now(),
    decided_at timestamptz
);

alter table decision drop constraint decision_catalogue_check;
alter table decision add constraint decision_catalogue_check
    check (catalogue in ('triage', 'gate', 'preflight', 'capture'));
