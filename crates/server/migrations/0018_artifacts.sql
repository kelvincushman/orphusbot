-- Artifacts (DESIGN §11.1): files a bot shared with the owner. Sharing the same
-- name again from the same bot adds a version; older versions stay.

create table artifact (
    id bigint generated always as identity primary key,
    bot_id bigint not null references bot (id) on delete cascade,
    run_id bigint references run (id) on delete set null,
    name text not null check (length(name) between 1 and 200),
    version integer not null check (version > 0),
    content bytea not null check (octet_length(content) <= 10485760),
    created_at timestamptz not null default now(),
    unique (bot_id, name, version)
);
