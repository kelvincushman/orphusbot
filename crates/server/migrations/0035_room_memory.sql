-- The Ideas Room's memory (DESIGN §12.5): each live conversation, the ideas
-- saved in it and the owner's rating, so the next one starts where he left off.
create table room_session (
    id bigserial primary key,
    started_at timestamptz not null default now(),
    ended_at timestamptz,
    transcript text not null default '' check (length(transcript) <= 200000),
    rating smallint check (rating in (-1, 1)),
    note text check (length(note) <= 2000)
);

create table room_idea (
    id bigserial primary key,
    session_id bigint references room_session (id) on delete set null,
    title text not null check (length(title) between 1 and 200),
    brief text not null check (length(brief) <= 20000),
    created_at timestamptz not null default now()
);
