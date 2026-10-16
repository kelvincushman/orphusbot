-- E2B computers (DESIGN §6.2): a bot's computer can live in an E2B sandbox
-- instead of a container on a node. The engine still runs on a node.

alter table bot add column computer text not null default 'node' check (computer in ('node', 'e2b'));

-- The bot's sandbox. It pauses itself when idle and resumes on the next run,
-- so its files last like a home volume.
create table bot_sandbox (
    bot_id bigint primary key references bot (id) on delete cascade,
    sandbox_id text not null check (length(sandbox_id) between 1 and 100),
    created_at timestamptz not null default now()
);
