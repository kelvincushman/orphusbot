-- Capture profiles (DESIGN §10.5, PRD B-CAP-04): one owner-wide profile that
-- decides which kinds are kept, when digests come, whether notes file
-- themselves, whether dismissed commitments come back, and nudges.

create table capture_settings (
    id integer primary key default 1 check (id = 1),
    profile text not null default 'focus' check (profile in ('focus', 'standard')),
    -- Digests and nudges use this clock.
    timezone text not null default 'Europe/London' check (length(timezone) between 1 and 64),
    last_digest_at timestamptz
);
insert into capture_settings default values;

-- Filed without a click (an idea or something to remember, Focus support); can be undone for 24 h.
alter table proposal add column auto_filed boolean not null default false;
-- A dismissed commitment that came back once (Focus support).
alter table proposal add column resurfaced boolean not null default false;
-- When it's due, if the extractor could work out a time ("tomorrow 3pm"); nudges use it.
alter table proposal add column due_at timestamptz;

-- Nudges already sent, so each goes once: 30, 10 and 0 minutes before.
create table nudge (
    proposal_id bigint not null references proposal (id) on delete cascade,
    minutes integer not null check (minutes in (0, 10, 30)),
    sent_at timestamptz not null default now(),
    primary key (proposal_id, minutes)
);
