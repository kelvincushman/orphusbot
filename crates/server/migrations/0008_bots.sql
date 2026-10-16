-- Bots (PRD B-BOT-01, B-BOT-03; DESIGN §3.1). Each bot is an Orphus engine with its
-- own instructions, model and computer, and one thread of conversation.

create table bot (
    id bigint generated always as identity primary key,
    -- Names its engine session, computer and home volume, so it never changes.
    slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{0,30}$'),
    name text not null check (length(name) between 1 and 40),
    -- One line saying what it's for; System 1 routes by it.
    remit text not null default '' check (length(remit) <= 200),
    instructions text not null default '' check (length(instructions) <= 8000),
    -- Orphus `--model` and `--thinking`; null means Orphus's default.
    model text check (model is null or length(model) between 1 and 100),
    thinking text check (thinking in ('off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')),
    -- Orphus `--exclude-tools`.
    exclude_tools text[] not null default '{}',
    scope text not null default 'private' check (scope in ('team', 'private')),
    disabled boolean not null default false,
    created_at timestamptz not null default now()
);

-- The inbox bot always exists and takes whatever isn't clearly another bot's (B-BOT-03).
insert into bot (slug, name, remit)
values ('inbox', 'Inbox', 'Anything that isn''t clearly another bot''s');

create sequence thread_id_seq start 2 owned by thread.id;
alter table thread alter column id set default nextval('thread_id_seq');
alter table thread add column bot_id bigint unique references bot (id);
update thread set bot_id = (select id from bot where slug = 'inbox') where id = 1;
alter table thread alter column bot_id set not null;

-- One stream for all threads: clients resume from the last event id they saw.
alter table event add column id bigint generated always as identity;
alter table event add constraint event_id_unique unique (id);

-- The single bot's computer was keyed "orphus"; it is the inbox bot's now.
update bot_computer set bot = 'inbox' where bot = 'orphus';
