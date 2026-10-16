-- Tickets (PRD B-TKT-01..03): a board of work with a status, urgency and an
-- assigned bot. Assigning one starts the bot on it; its run moves it along.

create type ticket_status as enum ('todo', 'doing', 'review', 'blocked', 'done');

create table ticket (
    id bigint generated always as identity primary key,
    title text not null check (length(title) between 1 and 200),
    body text not null default '' check (length(body) <= 8000),
    status ticket_status not null default 'todo',
    -- DESIGN §7.2 `triage.urgency`.
    urgency text not null default 'today' check (urgency in ('whenever', 'today', 'hour', 'now')),
    bot_id bigint references bot (id),
    -- System 1 thought it safe to start without asking (DESIGN §7.2 `triage.act_now`).
    act_now boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table run add column ticket_id bigint references ticket (id) on delete set null;
