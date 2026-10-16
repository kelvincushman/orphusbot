-- Threads and their append-only event log (DESIGN §3.1, §3.2).
-- Each thread hands out its own gap-free sequence numbers; clients resume from
-- the last one they saw.

create table thread (
    id bigint primary key,
    last_seq bigint not null default 0 check (last_seq >= 0)
);

create table event (
    thread_id bigint not null references thread (id),
    seq bigint not null check (seq > 0),
    body jsonb not null,
    created_at timestamptz not null default now(),
    primary key (thread_id, seq)
);

-- M0 has one thread, for the one bot.
insert into thread (id) values (1);
