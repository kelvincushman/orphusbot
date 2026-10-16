-- Pictures and files the owner sends a bot (DESIGN §12.1). They go into the
-- bot's computer (inbox/) with the run, and pictures to the model as images.

create table attachment (
    id bigint generated always as identity primary key,
    bot_id bigint not null references bot (id) on delete cascade,
    name text not null check (length(name) between 1 and 200),
    mime text not null check (length(mime) between 1 and 100),
    content bytea not null check (octet_length(content) <= 10485760),
    created_at timestamptz not null default now()
);

-- The attachments a run carries to its node.
alter table run add column attachments bigint[] not null default '{}';
