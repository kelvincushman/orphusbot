-- Missions (DESIGN §5.5, D-064): a new piece of work with its own Chief of Staff.
-- The chief is a bot row, `chief--<id>`, so it has its own thread and engine.
create table mission (
    id bigint generated always as identity primary key,
    title text not null check (length(title) between 1 and 200),
    goal text not null check (length(goal) between 1 and 8000),
    status text not null default 'open' check (status in ('open', 'done', 'dropped')),
    -- Visible to the team unless marked private (the owner's choice).
    private boolean not null default false,
    -- The chief's latest one-line progress.
    latest text not null default '' check (length(latest) <= 1000),
    -- Who's working on it: the slugs it started with and anyone handed work since.
    team text[] not null default '{}',
    -- The node has dropped the closed chief's engine and stopped its computer.
    retired boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- A hand-off from a chief: its run uses the bot's session for this mission.
alter table ticket add column mission_id bigint references mission (id) on delete set null;

-- Bumped by "New conversation": the bot's engine moves to a fresh session.
alter table bot add column session_gen integer not null default 0 check (session_gen >= 0);
