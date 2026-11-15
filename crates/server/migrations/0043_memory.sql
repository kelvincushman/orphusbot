-- What OrphusBot learns about the owner from what he says (DESIGN §11.9, D-066).

-- What the owner said to a bot, kept until the learner has read it, and after
-- that as the source a fact points back to.
create table memory_heard (
    id bigint generated always as identity primary key,
    thread_id bigint not null references thread (id),
    text text not null check (length(text) between 1 and 8000),
    heard_at timestamptz not null default now(),
    learned_at timestamptz,
    attempts smallint not null default 0
);
create index memory_heard_unlearned on memory_heard (thread_id, id) where learned_at is null;

-- One thing known about the owner: a single self-contained sentence.
create table memory_fact (
    id bigint generated always as identity primary key,
    text text not null check (length(text) between 1 and 400),
    -- From the embedding model; compared in the server (no pgvector needed).
    embedding real[] not null,
    times_seen integer not null default 1 check (times_seen > 0),
    created_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    -- Set when a later fact took its place (he changed his mind, or it changed).
    replaced_by bigint references memory_fact (id) on delete set null
);
create index memory_fact_current on memory_fact (last_seen_at desc) where replaced_by is null;

create table memory_fact_source (
    fact_id bigint not null references memory_fact (id) on delete cascade,
    heard_id bigint not null references memory_heard (id) on delete cascade,
    primary key (fact_id, heard_id)
);
