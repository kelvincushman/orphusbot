-- Discussions (DESIGN §11.4): chosen bots deliberate on a question in one
-- Orphus room, round by round, then a chair writes the verdict and files the
-- room into memory.
create table discussion (
    id bigint generated always as identity primary key,
    question text not null check (length(question) between 1 and 4000),
    bots text[] not null check (cardinality(bots) between 2 and 6),
    chair text not null,
    rounds integer not null check (rounds between 1 and 4),
    -- The round being worked on; rounds + 1 is the chair's verdict.
    round integer not null default 1,
    status text not null default 'running' check (status in ('running', 'done', 'failed')),
    verdict text,
    created_at timestamptz not null default now(),
    finished_at timestamptz
);

-- Each turn is an ordinary run of that bot, tagged with its discussion and round.
alter table run add column discussion_id bigint references discussion (id) on delete set null;
alter table run add column discussion_round integer;

-- What the bots posted in the room, as seen at the gate.
create table discussion_post (
    id bigint generated always as identity primary key,
    discussion_id bigint not null references discussion (id) on delete cascade,
    bot text not null,
    round integer not null,
    text text not null,
    created_at timestamptz not null default now()
);
create index discussion_post_by_discussion on discussion_post (discussion_id, id);
